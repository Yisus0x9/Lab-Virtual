#!/bin/bash
# Remote lab script for VHDL in VPL
# Compiles the submitted VHDL files with GHDL and launches an interactive simulation.

log_info()    { echo "SUCCESS:=> $*"; }
log_error()   { echo "ERROR:=> $*"; }
log_success() { echo "Comment :=>>$*"; }

. common_script.sh

log_info "Remote lab: searching source files..."

get_source_files v sv vh NOERROR
if [ "$?" != "0" ]; then
    get_source_files vhd vhdl NOERROR
fi

if [ -z "$SOURCE_FILES" ]; then
    log_error "No source files found."
    exit 1
fi

SAVEIFS=$IFS
IFS=$'\n'

for FILENAME in $SOURCE_FILES; do
    log_info "Analyzing: $FILENAME"
    ghdl -a --std=08 "$FILENAME"
    if [ $? -ne 0 ]; then
        log_error "Analysis failed for $FILENAME"
        IFS=$SAVEIFS
        exit 1
    fi
done

IFS=$SAVEIFS
log_success "All source files analyzed. Ready for simulation."

# Detect top-level entity from the last source file.
TOPLEVEL=$(ghdl --list-files 2>/dev/null | head -1 | sed 's/\.vhd$//' | tr '[:upper:]' '[:lower:]')

if [ -z "$TOPLEVEL" ]; then
    log_error "Could not determine top-level entity."
    exit 1
fi

log_info "Elaborating top-level entity: $TOPLEVEL"
ghdl -e --std=08 "$TOPLEVEL"
if [ $? -ne 0 ]; then
    log_error "Elaboration failed."
    exit 1
fi

log_success "Elaboration successful. Launching remote lab simulation..."
ghdl -r --std=08 "$TOPLEVEL" --wave=output.ghw 2>&1
