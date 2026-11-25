#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

from contextlib import contextmanager
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
THIRD_PARTY_DIR = REPO_ROOT / "third-party"
TEMP_DEVICE_NAME = "skills-collection-ephemeral"


def run(
    cmd: list[str],
    cwd: Path = REPO_ROOT,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, check=check, text=True, capture_output=capture)


def check_host_dependencies(require_git_clean: bool = False, require_skillm: bool = False) -> None:
    required_bins = ["incus", "git"]
    if require_skillm:
        required_bins.append("skillm")

    missing = [b for b in required_bins if shutil.which(b) is None]
    if missing:
        sys.exit(f"Error: faltan herramientas requeridas en el host: {', '.join(missing)}")

    if require_git_clean:
        status = run(["git", "status", "--porcelain"]).stdout.strip()
        if status:
            sys.exit(
                "Error: el repositorio tiene cambios sin commitear.\n"
                "Haz commit o stash antes de ejecutar sync/upgrade para no mezclar cambios:\n"
                f"{status}"
            )


def ensure_container_running(container: str) -> None:
    res = run(["incus", "list", container, "--format=csv", "-c", "s"], check=False)
    state = res.stdout.strip()
    if not state:
        sys.exit(f"Error: el contenedor Incus '{container}' no existe.")
    if state.lower() != "running":
        sys.exit(f"Error: el contenedor '{container}' está en estado '{state}' (se requiere 'Running').")


def incus_exec(
    container: str,
    user: str,
    shell_cmd: str,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess:
    return run(
        ["incus", "exec", container, "--", "su", "-", user, "-c", shell_cmd],
        check=check,
        capture=capture,
    )


@contextmanager
def ensure_repo_mounted(container: str, mount_path: str):
    """Garantiza que REPO_ROOT esté disponible como readonly en mount_path.
    Si no existe, lo monta temporalmente y lo elimina al salir."""
    probe = run(["incus", "exec", container, "--", "test", "-d", f"{mount_path}/.git"], check=False)
    mounted_by_us = False

    if probe.returncode != 0:
        print(f"→ Montando temporalmente {REPO_ROOT} en {container}:{mount_path} (readonly)...")
        run([
            "incus", "config", "device", "add", container, TEMP_DEVICE_NAME, "disk",
            f"source={REPO_ROOT}",
            f"path={mount_path}",
            "readonly=true",
            "shift=true",
        ])
        mounted_by_us = True

    try:
        yield
    finally:
        if mounted_by_us:
            print(f"→ Desmontando dispositivo temporal '{TEMP_DEVICE_NAME}'...")
            run(["incus", "config", "device", "remove", container, TEMP_DEVICE_NAME], check=False)


def discover_skills(target: str) -> list[Path]:
    skills = sorted(p.parent for p in THIRD_PARTY_DIR.glob("*/upstream.toml"))
    if target == "all":
        return skills
    selected = [s for s in skills if s.name == target]
    if not selected:
        sys.exit(f"Error: no se encontró 'third-party/{target}/upstream.toml'")
    return selected


def get_recorded_version(skill_dir: Path) -> str:
    vfile = skill_dir / ".upstream-version"
    return vfile.read_text().strip() if vfile.exists() else "none"


def get_remote_version(cfg: dict) -> str:
    up = cfg["upstream"]
    res = incus_exec(up["container"], up["user"], up["version_cmd"])
    ver = res.stdout.strip()
    if not ver:
        sys.exit(f"Error: no se pudo determinar la versión remota usando: {up['version_cmd']}")
    return ver


def pull_to_temp(cfg: dict, tmp_dir: Path) -> None:
    up = cfg["upstream"]
    container = up["container"]
    for fname in up["files"]:
        remote_fs_path = f"{up['source_dir']}/{fname}"
        exists = run(["incus", "exec", container, "--", "test", "-f", remote_fs_path], check=False)
        if exists.returncode != 0:
            sys.exit(f"Error: el archivo esperado '{remote_fs_path}' no existe en '{container}'.")
        run(["incus", "file", "pull", f"{container}{remote_fs_path}", str(tmp_dir / fname)])


def has_file_drift(skill_dir: Path, tmp_dir: Path, files: list[str]) -> bool:
    for fname in files:
        local_file = skill_dir / fname
        pulled_file = tmp_dir / fname
        if not local_file.exists() or local_file.read_bytes() != pulled_file.read_bytes():
            return True
    return False


def ask_pi_commit_msg(cfg: dict, skill_name: str, old_ver: str, new_ver: str) -> str:
    up = cfg["upstream"]
    container = up["container"]
    user = up["user"]
    commit_cfg = cfg.get("commit", {})
    repo_mount = commit_cfg.get("pi_repo_mount", "/mnt/skills-collection")
    scope = commit_cfg.get("scope", "third-party")

    pi_check = incus_exec(container, user, "command -v pi", check=False)
    if pi_check.returncode != 0:
        print("! Aviso: 'pi' no está disponible en el contenedor; usando mensaje estándar.")
        return f"docs({scope}): sync {skill_name} skill to {new_ver}"

    prompt = (
        f"Revisa el git diff en third-party/{skill_name} y los últimos commits con git log -n 5. "
        f"Responde ÚNICAMENTE con un mensaje de commit en formato Conventional Commits "
        f"(primera línea: docs({scope}): sync {skill_name} skill to {new_ver}, seguida de una línea en blanco y un párrafo corto "
        f"resumiendo los cambios funcionales clave respecto a {old_ver}). Sin bloques markdown ni texto adicional."
    )

    with ensure_repo_mounted(container, repo_mount):
        cmd = f"cd {repo_mount} && pi -p {subprocess.list2cmdline([prompt])}"
        res = incus_exec(container, user, cmd)

    msg = res.stdout.strip().strip("`")
    return msg if msg else f"docs({scope}): sync {skill_name} skill to {new_ver}"


def cmd_status(skills: list[Path]) -> None:
    print(f"{'SKILL':<25} {'VERSION REGISTRADA':<20} {'ORIGEN'}")
    print("-" * 70)
    for s in skills:
        cfg = tomllib.loads((s / "upstream.toml").read_text())
        ver = get_recorded_version(s)
        origin = f"{cfg['upstream']['type']}:{cfg['upstream']['container']}"
        print(f"{s.name:<25} {ver:<20} {origin}")


def cmd_check(skills: list[Path]) -> None:
    check_host_dependencies()
    for s in skills:
        cfg = tomllib.loads((s / "upstream.toml").read_text())
        ensure_container_running(cfg["upstream"]["container"])
        old_ver = get_recorded_version(s)
        new_ver = get_remote_version(cfg)
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            pull_to_temp(cfg, tmp_path)
            drift = has_file_drift(s, tmp_path, cfg["upstream"]["files"])

        if old_ver == new_ver and not drift:
            print(f"✓ {s.name}: al día ({new_ver})")
        else:
            print(f"! {s.name}: cambios detectados (registrado: {old_ver} -> actual: {new_ver}, drift archivos: {drift})")


def cmd_upgrade(skills: list[Path]) -> None:
    check_host_dependencies(require_git_clean=True, require_skillm=True)
    for s in skills:
        cfg = tomllib.loads((s / "upstream.toml").read_text())
        up = cfg["upstream"]
        ensure_container_running(up["container"])
        print(f"→ Ejecutando upgrade en {up['container']} para {s.name}...")
        incus_exec(up["container"], up["user"], up["upgrade_cmd"], capture=False)
    cmd_sync(skills)


def cmd_sync(skills: list[Path]) -> None:
    check_host_dependencies(require_git_clean=True, require_skillm=True)
    for s in skills:
        cfg = tomllib.loads((s / "upstream.toml").read_text())
        up = cfg["upstream"]
        ensure_container_running(up["container"])
        old_ver = get_recorded_version(s)
        new_ver = get_remote_version(cfg)

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            pull_to_temp(cfg, tmp_path)
            drift = has_file_drift(s, tmp_path, up["files"])

            if old_ver == new_ver and not drift:
                print(f"✓ {s.name}: sin cambios que sincronizar ({new_ver}).")
                continue

            print(f"\n=== Sincronizando {s.name} ({old_ver} -> {new_ver}) ===")
            for fname in up["files"]:
                shutil.copy2(tmp_path / fname, s / fname)
            (s / ".upstream-version").write_text(f"{new_ver}\n")

        try:
            diff_stat = run(["git", "diff", "--stat", str(s)]).stdout.strip()
            print(f"\nResumen de cambios en working tree:\n{diff_stat}\n")

            if cfg.get("commit", {}).get("use_pi", False):
                print("Consultando a Pi en el contenedor para redactar el commit...")
                commit_msg = ask_pi_commit_msg(cfg, s.name, old_ver, new_ver)
            else:
                scope = cfg.get("commit", {}).get("scope", "third-party")
                commit_msg = f"docs({scope}): sync {s.name} skill to {new_ver}"

            print("\n--- Mensaje de commit propuesto ---")
            print(commit_msg)
            print("-----------------------------------\n")

            answer = input("¿Confirmar git commit, git push y skillm update? [y/N]: ").strip().lower()
            if answer != "y":
                print("Operación cancelada. Revirtiendo cambios en el working tree...")
                run(["git", "checkout", "--", str(s)])
                continue

            run(["git", "add", str(s)], capture=False)
            run(["git", "commit", "-m", commit_msg], capture=False)
            run(["git", "push"], capture=False)

            print(f"\n→ Actualizando {s.name} en skillm...")
            run(["skillm", "update", s.name], capture=False)
            print(f"✓ {s.name} sincronizado y desplegado correctamente.")
        except BaseException:
            # Si algo falla o se interrumpe con Ctrl+C antes del commit, deja el repo limpio
            run(["git", "checkout", "--", str(s)], check=False)
            raise


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("Uso: sync_upstream.py <status|check|upgrade|sync> [skill|all]")
    action = sys.argv[1]
    target = sys.argv[2] if len(sys.argv) > 2 else "all"
    skills = discover_skills(target)

    if action == "status":
        cmd_status(skills)
    elif action == "check":
        cmd_check(skills)
    elif action == "upgrade":
        cmd_upgrade(skills)
    elif action == "sync":
        cmd_sync(skills)
    else:
        sys.exit(f"Acción desconocida: {action}")


if __name__ == "__main__":
    main()
