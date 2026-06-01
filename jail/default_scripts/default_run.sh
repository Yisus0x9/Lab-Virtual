#!/bin/bash
# This file is part of VPL for Moodle
# Default run script for VPL
# Copyright (C) 2012 Juan Carlos Rodríguez-del-Pino
# License http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
# Author Jesus Peñarrieta Villa , Jonathan Treviño Hernández

# Logs para ver en la terminal de texto de vpl
log_info()    { echo "-INFO:=>  $*"; }
log_error()   { echo "-ERROR:=> $*"; }
log_success() { echo "-SUCCESS:> $*"; }

. common_script.sh

get_source_files v sv vh NOERROR
if [ "$?" != "0" ]; then
    get_source_files vhd vhdl NOERROR
fi

if [ -z "$SOURCE_FILES" ]; then
    log_error "No se encontraron archivos fuente."
    exit 1
fi

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