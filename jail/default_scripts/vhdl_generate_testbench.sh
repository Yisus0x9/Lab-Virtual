#!/bin/bash
# Generate testbench script for VHDL in VPL
# Reads the submitted VHDL entity and generates a basic testbench template.

log_info()    { echo "SUCCESS:=> $*"; }
log_error()   { echo "ERROR:=> $*"; }
log_success() { echo "Comment :=>>$*"; }

. common_script.sh

log_info "Testbench generator: searching source files..."

get_source_files v sv vh NOERROR
if [ "$?" != "0" ]; then
    get_source_files vhd vhdl NOERROR
fi

if [ -z "$SOURCE_FILES" ]; then
    log_error "No source files found."
    exit 1
fi

FIRST_FILE=$(echo "$SOURCE_FILES" | head -1)
ENTITY_NAME=$(grep -i 'entity' "$FIRST_FILE" | grep -i 'is' | head -1 | awk '{print $2}' | tr '[:upper:]' '[:lower:]')

if [ -z "$ENTITY_NAME" ]; then
    log_error "Could not detect entity name in $FIRST_FILE."
    exit 1
fi

log_info "Detected entity: $ENTITY_NAME"

PORTS=$(awk '/port\s*\(/,/\);/' "$FIRST_FILE" 2>/dev/null | grep -v 'port' | grep -v ');' | sed 's/^[[:space:]]*/    /')

TBFILE="tb_${ENTITY_NAME}.vhd"

cat > "$TBFILE" <<TBTEMPLATE
library ieee;
use ieee.std_logic_1164.all;

entity tb_${ENTITY_NAME} is
end entity tb_${ENTITY_NAME};

architecture sim of tb_${ENTITY_NAME} is

    -- Declare signals for each port of ${ENTITY_NAME}.
    -- TODO: declare signals here.

    component ${ENTITY_NAME}
        port (
${PORTS}
        );
    end component;

begin

    uut: ${ENTITY_NAME}
        port map (
            -- TODO: connect signals here.
        );

    stimulus: process
    begin
        -- TODO: add stimulus here.
        wait;
    end process;

end architecture sim;
TBTEMPLATE

if [ $? -eq 0 ]; then
    log_success "Testbench generated: $TBFILE"
    echo ""
    cat "$TBFILE"
else
    log_error "Failed to generate testbench."
    exit 1
fi
