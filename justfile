# Interfaz genérica para gestión de skills de terceros en skills-collection

set shell := ["bash", "-euo", "pipefail", "-c"]

# Lista las skills disponibles y su última versión sincronizada
status:
    @uv run --script scripts/sync_upstream.py status

# Verifica si hay nueva versión o drift de archivos (ej: just check zotero-cli | just check all)
check skill="all":
    @uv run --script scripts/sync_upstream.py check {{skill}}

# Ejecuta el upgrade en el origen y sincroniza si hubo cambios (ej: just upgrade zotero-cli)
upgrade skill="all":
    @uv run --script scripts/sync_upstream.py upgrade {{skill}}

# Extrae archivos, analiza diff con Pi, pide confirmación, commitea, pushea y actualiza skillm
sync skill="all":
    @uv run --script scripts/sync_upstream.py sync {{skill}}
