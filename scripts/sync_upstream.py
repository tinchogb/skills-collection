#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///

import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
THIRD_PARTY_DIR = REPO_ROOT / "third-party"


def run(cmd: list[str], cwd: Path = REPO_ROOT, check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, check=check, text=True, capture_output=capture)


def incus_exec(container: str, user: str, shell_cmd: str, capture: bool = True) -> subprocess.CompletedProcess:
    return run(["incus", "exec", container, "--", "su", "-", user, "-c", shell_cmd], capture=capture)


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
    return res.stdout.strip()


def pull_to_temp(cfg: dict, tmp_dir: Path) -> None:
    up = cfg["upstream"]
    for fname in up["files"]:
        remote_path = f"{up['container']}{up['source_dir']}/{fname}"
        run(["incus", "file", "pull", remote_path, str(tmp_dir / fname)])


def has_file_drift(skill_dir: Path, tmp_dir: Path, files: list[str]) -> bool:
    for fname in files:
        local_file = skill_dir / fname
        pulled_file = tmp_dir / fname
        if not local_file.exists():
            return True
        if local_file.read_bytes() != pulled_file.read_bytes():
            return True
    return False


def ask_pi_commit_msg(cfg: dict, skill_name: str, old_ver: str, new_ver: str) -> str:
    up = cfg["upstream"]
    commit_cfg = cfg.get("commit", {})
    repo_mount = commit_cfg.get("pi_repo_mount", "/mnt/skills-collection")
    scope = commit_cfg.get("scope", "third-party")

    prompt = (
        f"Revisa el git diff en third-party/{skill_name} y los últimos commits con git log -n 5. "
        f"Responde ÚNICAMENTE con un mensaje de commit en formato Conventional Commits "
        f"(primera línea: docs({scope}): sync {skill_name} skill to {new_ver}, seguida de una línea en blanco y un párrafo corto "
        f"resumiendo los cambios funcionales clave respecto a {old_ver}). Sin bloques markdown ni texto adicional."
    )
    cmd = f"cd {repo_mount} && pi -p {subprocess.list2cmdline([prompt])}"
    res = incus_exec(up["container"], up["user"], cmd)
    return res.stdout.strip().strip("`")


def cmd_status(skills: list[Path]) -> None:
    print(f"{'SKILL':<25} {'VERSION REGISTRADA':<20} {'ORIGEN'}")
    print("-" * 70)
    for s in skills:
        cfg = tomllib.loads((s / "upstream.toml").read_text())
        ver = get_recorded_version(s)
        origin = f"{cfg['upstream']['type']}:{cfg['upstream']['container']}"
        print(f"{s.name:<25} {ver:<20} {origin}")


def cmd_check(skills: list[Path]) -> None:
    for s in skills:
        cfg = tomllib.loads((s / "upstream.toml").read_text())
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
    for s in skills:
        cfg = tomllib.loads((s / "upstream.toml").read_text())
        up = cfg["upstream"]
        print(f"→ Ejecutando upgrade en {up['container']} para {s.name}...")
        incus_exec(up["container"], up["user"], up["upgrade_cmd"], capture=False)
    cmd_sync(skills)


def cmd_sync(skills: list[Path]) -> None:
    for s in skills:
        cfg = tomllib.loads((s / "upstream.toml").read_text())
        up = cfg["upstream"]
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
            print("Operación cancelada. Los cambios quedan en tu working tree para revisión manual.")
            continue

        run(["git", "add", str(s)], capture=False)
        run(["git", "commit", "-m", commit_msg], capture=False)
        run(["git", "push"], capture=False)

        print(f"\n→ Actualizando {s.name} en skillm...")
        run(["skillm", "update", s.name], capture=False)
        print(f"✓ {s.name} sincronizado y desplegado correctamente.")


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
