#!/bin/bash
# This file is part of VPL for Moodle
# Default debug script for VPL
# Copyright (C) 2012 Juan Carlos Rodríguez-del-Pino
# License http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
# Author Jesus Peñarrieta Villa
# Logs
log_info()    { echo "-INFO:=>  $*"; }
log_error()   { echo "-ERROR:=> $*"; }
log_success() { echo "-SUCCESS:> $*"; }
log_debug()   { [ "$DEBUG_MODE" == "1" ] && echo "DEBUG:=> $*"; }

. common_script.sh

# ============================================================================
# ACTIVAR MODO DEBUG SI SE PASA COMO PARÁMETRO
# ============================================================================
DEBUG_MODE="0"
if [ "$3" == "debug" ] || [ "$2" == "debug" ]; then
    DEBUG_MODE="1"
    log_info "MODO DEBUG ACTIVADO"
    set -x  # Mostrar cada comando
fi

check_program gtkwave NOERROR
if [ "$1" == "version" ]; then
    get_program_version --version
fi

# ============================================================================
# FASE 1: COMPILAR FUENTES
# ============================================================================
log_info "Compilando archivos fuente..."
./vpl_run.sh
if [ $? -ne 0 ]; then
    log_error "Falló la compilación de archivos fuente."
    exit 1
fi

# ============================================================================
# FASE 2: DETECTAR ARCHIVOS VHDL
# ============================================================================
log_info "Buscando archivos .vhd y .vhdl..."

declare -a ALL_VHDL_FILES
declare -a TESTBENCH_FILES
SOURCE_FILES=()

# Recopilar todos los archivos VHDL
for file in *.vhd *.vhdl; do
    if [ -e "$file" ]; then
        ALL_VHDL_FILES+=("$file")
        log_debug "Archivo VHDL encontrado: $file"
    fi
done

if [ ${#ALL_VHDL_FILES[@]} -eq 0 ]; then
    log_error "No se encontraron archivos .vhd o .vhdl"
    exit 1
fi

log_info "Total de archivos VHDL encontrados: ${#ALL_VHDL_FILES[@]}"

# ============================================================================
# FUNCIÓN: Extraer entidades
# ============================================================================
extract_entities() {
    local file="$1"
    grep -io "^[[:space:]]*entity[[:space:]]\+[a-zA-Z_][a-zA-Z0-9_]*" "$file" | \
        sed 's/entity//I' | sed 's/^[[:space:]]*//g' | sort -u
}

# ============================================================================
# FUNCIÓN: Extraer componentes
# ============================================================================
extract_components() {
    local file="$1"
    grep -io "component[[:space:]]\+[a-zA-Z_][a-zA-Z0-9_]*" "$file" | \
        sed 's/component//I' | sed 's/^[[:space:]]*//g' | sort -u
}

# ============================================================================
# FUNCIÓN: Detectar testbench por heurística
# ============================================================================
is_testbench() {
    local file="$1"
    
    log_debug "Analizando si es testbench: $file"
    
    # Buscar patrones típicos de testbench
    local patterns=0
    
    grep -qi "uut" "$file" && { patterns=$((patterns+1)); log_debug "   Encontrado: 'uut'"; }
    grep -qi "stimulus" "$file" && { patterns=$((patterns+1)); log_debug "   Encontrado: 'stimulus'"; }
    grep -qi "dut" "$file" && { patterns=$((patterns+1)); log_debug "   Encontrado: 'dut'"; }

    # Si tiene al menos 1 patrón, es testbench
    if [ $patterns -gt 0 ]; then
        log_debug "   Detectado como TESTBENCH ($patterns patrones)"
        return 0
    else
        log_debug "   Detectado como FUENTE"
        return 1
    fi
}

# ============================================================================
# CLASIFICAR ARCHIVOS
# ============================================================================
log_info "Clasificando archivos..."
for file in "${ALL_VHDL_FILES[@]}"; do
    if is_testbench "$file"; then
        TESTBENCH_FILES+=("$file")
        log_info "   Testbench: $file"
    else
        SOURCE_FILES+=("$file")
        log_info "  ○ Fuente: $file"
    fi
done

TB_COUNT=${#TESTBENCH_FILES[@]}
SRC_COUNT=${#SOURCE_FILES[@]}

log_info "Clasificación completa: $TB_COUNT testbench(es), $SRC_COUNT fuente(s)"

if [ "$TB_COUNT" -eq 0 ]; then
    log_error "No se detectó ningún testbench."
    exit 1
fi

# ============================================================================
# FASE 3: SIMULAR CADA TESTBENCH
# ============================================================================
GHW_FILES=()

for TB_FILE in "${TESTBENCH_FILES[@]}"; do
    log_info "Procesando testbench: $TB_FILE"
    
    # Extraer entidad del testbench
    TESTBENCH_NAME=$(extract_entities "$TB_FILE" | head -n 1)
    
    if [ -z "$TESTBENCH_NAME" ]; then
        log_error "No se pudo extraer entidad de $TB_FILE"
        continue
    fi
    
    log_info "Entidad testbench: $TESTBENCH_NAME"
    
    # ========================================================================
    # DETECTAR stime-stop EN EL ARCHIVO TESTBENCH
    # ========================================================================
    TB_STOP_TIME=""
    CUSTOM_STOP_TIME=""
    
    # Buscar patrón: stime-stop = [número] [opcional espacios] [unidad]
    # Captura: "3 ms", "3ms", "3  ms", etc.
    CUSTOM_STOP_TIME=$(grep -Eio -- "--[[:space:]]*stime_stop[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*(ns|us|ms|s)" "$TB_FILE" | \
                       sed -E 's/--[[:space:]]*stime_stop[[:space:]]*=[[:space:]]*//' | \
                       head -n 1)
    
    [ -n "$CUSTOM_STOP_TIME" ] && log_debug "   Encontrado: $CUSTOM_STOP_TIME"
    
    if [ -n "$CUSTOM_STOP_TIME" ]; then
        log_info "Stop time detectado en archivo: $CUSTOM_STOP_TIME"
        
        # Extraer número y unidad por separado, luego concatenarlos sin espacios
        STOP_NUMBER=$(echo "$CUSTOM_STOP_TIME" | grep -oE "^[0-9]+")
        STOP_UNIT=$(echo "$CUSTOM_STOP_TIME" | grep -oE "(ns|us|ms|s)$")
        
        if [ -n "$STOP_NUMBER" ] && [ -n "$STOP_UNIT" ]; then
            TB_STOP_TIME="${STOP_NUMBER}${STOP_UNIT}"
            log_success " Stop time válido: $TB_STOP_TIME"
            log_debug "   Número: $STOP_NUMBER, Unidad: $STOP_UNIT"
            log_debug "   Usando stop time del archivo"
        else
            log_error "  Formato de stime-stop inválido: '$CUSTOM_STOP_TIME'"
            log_error "  Formatos válidos: 100ns, 3 ms, 5 us, 2  s"
            log_error "  Usando valor por defecto: ${2:-1ms}"
            TB_STOP_TIME="${2:-1ms}"
            log_debug "   Usando stop time por defecto"
        fi
    else
        # Usar parámetro de línea de comandos o default
        TB_STOP_TIME="${2:-1ms}"
        log_info "Stop time (por defecto): $TB_STOP_TIME"
        log_debug "   Ningún stime-stop en el archivo"
    fi
    
    # Extraer componentes que instancia
    TB_COMPONENTS=$(extract_components "$TB_FILE")
    
    if [ -n "$TB_COMPONENTS" ]; then
        log_info "Componentes instanciados:"
        echo "$TB_COMPONENTS" | while read comp; do
            [ -n "$comp" ] && log_info "   $comp"
        done
    else
        log_debug "No se encontraron componentes instanciados"
    fi
    
    # ========================================================================
    # COMPILAR DEPENDENCIAS
    # ========================================================================
    log_info "Buscando y compilando dependencias..."
    
    dep_count=0
    for src_file in "${SOURCE_FILES[@]}"; do
        log_debug "Analizando dependencias en: $src_file"
        SOURCE_ENTS=$(extract_entities "$src_file")
        log_debug "Entidades en $src_file: $(echo "$SOURCE_ENTS" | tr '\n' ',')"
        
        while IFS= read -r src_ent; do
            [ -z "$src_ent" ] && continue
            
            # Buscar si el testbench necesita esta entidad
            if echo "$TB_COMPONENTS" | grep -qi "^${src_ent}$"; then
                log_info "   Compilando: $src_file (entidad: $src_ent)"
                ghdl -a --std=08 "$src_file" 2>&1 | sed 's/^/      [GHDL] /'
                
                if [ ${PIPESTATUS[0]} -eq 0 ]; then
                    log_success "     Compilado correctamente"
                    dep_count=$((dep_count+1))
                else
                    log_error "     Error de compilación"
                fi
            fi
        done <<< "$SOURCE_ENTS"
    done
    
    log_info "Dependencias compiladas: $dep_count"
    
    # ========================================================================
    # COMPILAR TESTBENCH
    # ========================================================================
    log_info "Analizando testbench: $TB_FILE"
    ghdl -a --std=08 "$TB_FILE" 2>&1 | sed 's/^/  [GHDL] /'
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Error en análisis de $TB_FILE"
        continue
    fi
    log_success " Análisis OK"
    
    # ========================================================================
    # ELABORAR
    # ========================================================================
    log_info "Elaborando: $TESTBENCH_NAME"
    ghdl -e --std=08 "$TESTBENCH_NAME" 2>&1 | sed 's/^/  [GHDL] /'
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Error en elaboración de $TESTBENCH_NAME"
        continue
    fi
    log_success " Elaboración OK"
    
    # ========================================================================
    # SIMULAR
    # ========================================================================
    GHW_FILE="${TESTBENCH_NAME}.ghw"
    
    log_info "Simulando: $TESTBENCH_NAME"
    log_info "  Comando: ghdl -r --std=08 \"$TESTBENCH_NAME\" --vcd=\"$GHW_FILE\" --stop-time=\"$TB_STOP_TIME\""
    
    ghdl -r --std=08 "$TESTBENCH_NAME" --wave="$GHW_FILE" --stop-time="$TB_STOP_TIME" 2>&1 | sed 's/^/  [GHDL] /'
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Error en simulación de $TESTBENCH_NAME"
        rm -f "$GHW_FILE"
        continue
    fi
    
    # Validar VCD
    if [ -f "$GHW_FILE" ] && [ -s "$GHW_FILE" ]; then
        VCD_SIZE=$(du -h "$GHW_FILE" | cut -f1)
        log_success " VCD generado: $GHW_FILE ($VCD_SIZE)"
        GHW_FILES+=("$GHW_FILE")
    else
        log_error "VCD vacío o no generado: $GHW_FILE"
        rm -f "$GHW_FILE"
        continue
    fi
done

# ============================================================================
# VALIDAR RESULTADOS
# ============================================================================
if [ ${#GHW_FILES[@]} -eq 0 ]; then
    log_error "No se generó ningún archivo VCD"
    exit 1
fi

log_success "Se generaron ${#GHW_FILES[@]} archivo(s) VCD"

# ============================================================================
# GENERAR PROYECTO GTKWAVE
# ============================================================================
GTKW_FILE="simulacion.gtkw"
log_info "Generando proyecto GTKWave: $GTKW_FILE"

{
    echo "[*] Proyecto GTKWave generado automáticamente"
    echo "[*] Fecha: $(date)"
    echo "[*] Testbenches simulados: ${#GHW_FILES[@]}"
    echo ""
    
    for VCD in "${GHW_FILES[@]}"; do
        echo "[dumpfile] \"$VCD\""
        echo "[dumpfile_mtime] \"$(date)\""
        echo "[dumpfile_size] $(wc -c < "$VCD")"
        echo ""
    done
} > "$GTKW_FILE"

log_success " Proyecto GTKWave: $GTKW_FILE"

# ============================================================================
# SCRIPT DE EJECUCIÓN
# ============================================================================
cat << 'END_OF_SCRIPT' > vpl_execution
#!/bin/bash
GTKW_FILE="simulacion.gtkw"
if [ -f "$GTKW_FILE" ]; then
    gtkwave "$GTKW_FILE"
else
    GHW_FILE=$(find . -maxdepth 1 -name "*.vcd" | head -n 1)
    if [ -n "$GHW_FILE" ]; then
        echo "INFO:=> Abriendo VCD: $GHW_FILE"
        gtkwave "$GHW_FILE"
    else
        echo "ERROR:=> No hay archivos VCD"
        exit 1
    fi
fi
END_OF_SCRIPT

chmod +x vpl_execution

# ============================================================================
# CONFIGURAR GTKWAVE
# ============================================================================
mkdir -p .gtkwave 2>/dev/null
cat > .gtkwave/gtkwaverc << 'END_OF_CONFIG'
fontname_signals Monospace 8
fontname_waves Monospace 10
splash_disable 1
enable_horiz_grid 1
use_big_fonts 0
END_OF_CONFIG

# ============================================================================
# MODO GRÁFICO
# ============================================================================
mv vpl_execution vpl_wexecution
chmod +x vpl_wexecution