#!/bin/bash
# This file is part of VPL for Moodle
# Remote lab script for VHDL in VPL
# Transfers the submitted VHDL files to a remote lab over SSH and opens an
# interactive session. The connection data is provided by the IDE through the
# VPL_SSH_HOST / VPL_SSH_USER / VPL_SSH_PASS environment variables.
# License http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later

# Load VPL environment so the SSH credentials (VPL_SSH_*) sent by the IDE are available.
. common_script.sh

USER="$VPL_SSH_USER"
HOST="$VPL_SSH_HOST"
PASS="$VPL_SSH_PASS"
PORT=22

if [ -z "$HOST" ] || [ -z "$USER" ] || [ -z "$PASS" ]; then
    echo "ERROR: Debes ingresar el servidor, usuario y contraseña para conectarte al laboratorio remoto."
    exit 1
fi
CONNECT_TIMEOUT=8
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=${CONNECT_TIMEOUT} -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o GSSAPIAuthentication=no"

cat << EOF > vpl_execution
#!/bin/bash

USER="$USER"
HOST="$HOST"
PASS="$PASS"
PORT="$PORT"
CONNECT_TIMEOUT="$CONNECT_TIMEOUT"
SSH_OPTS="$SSH_OPTS"

# Verificar si sshpass está disponible
if ! command -v sshpass &> /dev/null; then
    echo "ERROR: sshpass no está instalado en este servidor."
    exit 1
fi

# Verificar conectividad antes de intentar SSH
echo "Verificando conexión con \$HOST:\$PORT..."
if ! timeout \$CONNECT_TIMEOUT bash -c "echo > /dev/tcp/\$HOST/\$PORT" 2>/dev/null; then
    echo "ERROR: No se puede alcanzar \$HOST:\$PORT (timeout \${CONNECT_TIMEOUT}s)."
    echo "Verifique que el servidor esté encendido y accesible desde esta red."
    exit 1
fi
echo "Conexión disponible."

# Recolectar archivos VHDL en una lista antes de transferir
FILES=()
for f in *.vhdl *.vhd *.v *.sv *.vh; do
    [ -f "\$f" ] && FILES+=("\$f")
done

if [ \${#FILES[@]} -gt 0 ]; then
    echo "Transfiriendo \${#FILES[@]} archivo(s) VHDL..."
    sshpass -p "\$PASS" scp \$SSH_OPTS "\${FILES[@]}" "\${USER}@\${HOST}:~/" && \
        echo "Transferencia completada." || \
        echo "Advertencia: error al transferir algunos archivos."
else
    echo "No se encontraron archivos .vhdl/.vhd para transferir."
fi

# Iniciar sesión SSH interactiva
echo "Conectando a \$HOST..."
sshpass -p "\$PASS" ssh -t \$SSH_OPTS "\${USER}@\${HOST}"
EOF

chmod +x vpl_execution

echo $(ls)