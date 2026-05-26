#!/bin/bash
# Logs para ver en la terminal de texto de vpl
log_info()    { echo "-SUCCESS:=> $*"; }
log_error()   { echo "-ERROR:=> $*"; }
log_success() { echo "-Comment :=>>$*"; }

. common_script.sh

log_info "Buscando archivos fuente..."

get_source_files v sv vh NOERROR
if [ "$?" != "0" ]; then
    get_source_files vhd vhdl NOERROR
fi

if [ -z "$SOURCE_FILES" ]; then
    log_error "No se encontraron archivos fuente."
    exit 1
fi

log_success "Archivos encontrados."

# Compilar archivos
SAVEIFS=$IFS
IFS=$'\n'

for FILENAME in $SOURCE_FILES; do
    log_info "Compilado : $FILENAME"
    ghdl -a --std=08 "$FILENAME"
    if [ $? -ne 0 ]; then
        log_error "Falló la compilación de $FILENAME"
        IFS=$SAVEIFS
        exit 1
    fi
done

IFS=$SAVEIFS
log_success "Todos los archivos fuente compilados correctamente."