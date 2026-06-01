#!/bin/bash
# This file is part of VPL for Moodle
# Authors: Jesus Peñarrieta Villa , Jonathan Treviño Hernández , Jonathan Treviño Hernández
# Default remote download script for VPL
# Copies one or more files from the remote lab (over SSH) into the jail and
# prints their content (base64) framed by markers so Moodle can save them as
# student files.
# Connection data comes from the IDE through VPL_SSH_HOST / VPL_SSH_USER /
# VPL_SSH_PASS and the remote file(s) through VPL_REMOTE_FILE.
# VPL_REMOTE_FILE accepts:
#   - a single file:            caja.bit
#   - several comma separated:  caja.bit,caja.xdc
#   - a base path + files:      ruta:caja.bit,caja.xdc  -> ruta/caja.bit, ruta/caja.xdc
# License http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later

# Load VPL environment so the credentials (VPL_SSH_*) sent by the IDE are available.
. common_script.sh

USER="$VPL_SSH_USER"
HOST="$VPL_SSH_HOST"
PASS="$VPL_SSH_PASS"
FILE="$VPL_REMOTE_FILE"
PORT=22
CONNECT_TIMEOUT=8
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=${CONNECT_TIMEOUT} -o GSSAPIAuthentication=no"

cat << EOF > vpl_execution
#!/bin/bash

USER="$USER"
HOST="$HOST"
PASS="$PASS"
FILE="$FILE"
PORT="$PORT"
CONNECT_TIMEOUT="$CONNECT_TIMEOUT"
SSH_OPTS="$SSH_OPTS"

if [ -z "\$HOST" ] || [ -z "\$USER" ] || [ -z "\$PASS" ] || [ -z "\$FILE" ]; then
    echo "VPL_DOWNLOAD_ERROR:Faltan datos (servidor, usuario, contraseña o archivo)."
    exit 1
fi

if ! command -v sshpass &> /dev/null; then
    echo "VPL_DOWNLOAD_ERROR:sshpass no está instalado en el servidor de ejecución."
    exit 1
fi

# Parse VPL_REMOTE_FILE into an optional base path and a list of files.
DIR=""
LIST="\$FILE"
if [[ "\$FILE" == *:* ]]; then
    DIR="\${FILE%%:*}"
    LIST="\${FILE#*:}"
    # Trim surrounding spaces of the base path.
    DIR="\$(echo "\$DIR" | sed 's/^ *//;s/ *$//')"
fi

# Split the file list by commas into an array.
IFS=',' read -ra RAWFILES <<< "\$LIST"

DOWNLOADED=0
for RAW in "\${RAWFILES[@]}"; do
    # Trim spaces around each entry and skip empties.
    ENTRY="\$(echo "\$RAW" | sed 's/^ *//;s/ *$//')"
    [ -z "\$ENTRY" ] && continue

    if [ -n "\$DIR" ]; then
        REMOTE="\$DIR/\$ENTRY"
    else
        REMOTE="\$ENTRY"
    fi

    BASENAME="\$(basename "\$ENTRY")"
    LOCAL="./vpl_dl_\$BASENAME"

    sshpass -p "\$PASS" scp \$SSH_OPTS "\${USER}@\${HOST}:\${REMOTE}" "\$LOCAL" 2> vpl_download_err
    if [ \$? -ne 0 ]; then
        echo "VPL_DOWNLOAD_FILEERROR:\$ENTRY:\$(cat vpl_download_err | tr '\n' ' ')"
        continue
    fi

    echo "VPL_DOWNLOAD_NAME:\$BASENAME"
    echo "VPL_DOWNLOAD_BEGIN"
    base64 "\$LOCAL"
    echo "VPL_DOWNLOAD_END"
    DOWNLOADED=\$((DOWNLOADED+1))
done

if [ "\$DOWNLOADED" -eq 0 ]; then
    echo "VPL_DOWNLOAD_ERROR:No se pudo descargar ningún archivo."
    exit 1
fi
EOF

chmod +x vpl_execution
