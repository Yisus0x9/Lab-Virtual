#!/bin/bash
# This file is part of VPL for Moodle
# Default evaluate script for VPL
# Copyright (C) 2014 onwards Juan Carlos Rodríguez-del-Pino
# License http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
# Author Jesus Peñarrieta Villa
# ============================================================================
# VPL VHDL Evaluator v3.0
# Soporta código combinatorio y secuencial (FSM, registros, shift registers)
# ----------------------------------------------------------------------------
# Sintaxis del archivo vpl_evaluate.cases (todo con '='):
#
#   # Configuración global (todas opcionales, líneas con '#' son comentarios)
#   stop_time_all = 1 ms        # tope de simulación global
#   clock         = CLK         # nombre puerto reloj (auto-detect si se omite)
#   clock_period  = 10 ns       # período completo del reloj
#   reset         = RESET       # nombre puerto reset (auto-detect si se omite)
#   reset_active  = 0           # 1=activo alto, 0=activo bajo
#   reset_type    = async       # async | sync
#   reset_cycles  = 2           # ciclos manteniendo reset al inicio
#
#   # Caso combinatorio (sin clock => modo combinatorio automáticamente)
#   case = Prueba AND
#   grade reduction = 10%
#   stop_time = 50 ns           # opcional, tiempo a esperar tras aplicar entradas
#   input:
#       A = 00001111
#       B = 01010101
#   output:
#       Res = 00000101
#
#   # Caso secuencial: usa arrays [v0,v1,...] para múltiples ciclos
#   case = Detectar 1101
#   grade reduction = 50%
#   input:
#       X = [1, 1, 0, 1, 0, 1]      # un valor por ciclo
#       EN = 1                       # constante todos los ciclos
#   output:
#       Z2 = [_, _, _, 1, _, _]      # _ = no verificar este ciclo
# ============================================================================

set -o pipefail
. common_script.sh

log_info()    { echo "INFO:=>  $*"; }
log_error()   { echo "ERROR:=> $*"; }
log_success() { echo "SUCCESS:> $*"; }
log_warn()    { echo "WARN:=>  $*"; }

# Helper: escribe un vpl_execution válido (script bash) con grade mínimo y mensaje
fail_with_min_grade() {
    local msg="$1"
    {
        echo "#!/bin/bash"
        echo "echo"
        echo "echo '<|--'"
        if [ -n "$msg" ]; then
            while IFS= read -r ln; do
                esc=$(printf "%s" "$ln" | sed "s/'/'\\\\''/g")
                echo "echo '$esc'"
            done <<< "$msg"
        fi
        echo "echo '--|>'"
        echo "echo 'Grade :=>>$GRADE_MIN'"
    } > vpl_execution
    chmod +x vpl_execution
}

# ============================================================================
# CONFIGURACIÓN
# ============================================================================
CASES_FILE="vpl_evaluate.cases"
GENERATED_TB="__vpl_tb_generated.vhd"
TB_ENTITY="vpl_tb_generated"

GRADE_MIN=${VPL_GRADEMIN:-0}
GRADE_MAX=${VPL_GRADEMAX:-10}

# Defaults para modo secuencial (overridables desde .cases)
SIMULATION_STOP_TIME="1ms"
CLK_SIGNAL=""           # vacío => auto-detect
CLK_PERIOD="10 ns"
RESET_SIGNAL=""         # vacío => auto-detect
RESET_ACTIVE="1"        # 1=activo alto, 0=activo bajo
RESET_TYPE="async"      # async | sync
RESET_CYCLES="2"
GLOBAL_CASE_STOP="50 ns"   # default para wait combinatorio

EVAL_MODE="COMBINATORIAL"  # se decide más adelante

# Estructuras
CASE_NAMES=()
CASE_STOP_TIMES=()
CASE_GRADE_REDUCTIONS=()
CASE_INPUTS=()
CASE_OUTPUTS=()
CASE_IS_SEQUENTIAL=()

declare -A PORT_DIR     # nombre lower -> in/out
declare -A PORT_TYPE    # nombre lower -> std_logic / std_logic_vector(...)
declare -A PORT_ORIG    # nombre lower -> nombre original (preserva mayúsculas)
PORT_ORDER=()           # orden de aparición en la entidad

TOTAL_CASES=0

# ============================================================================
# PASO 1: COMPILAR FUENTES DEL ALUMNO
# ============================================================================
log_info "==== PASO 1: COMPILACIÓN ===="
./vpl_run.sh
if [ $? -ne 0 ]; then
    log_error "Falló la compilación del código del alumno."
    err_msg=$(cat vpl_compilation_error.txt 2>/dev/null)
    {
        echo "#!/bin/bash"
        echo "echo"
        echo "echo '<|--'"
        echo "echo '-Error de compilación'"
        # Imprimir cada línea del error con echo seguro
        while IFS= read -r ln; do
            esc=$(printf "%s" "$ln" | sed "s/'/'\\\\''/g")
            echo "echo '$esc'"
        done <<< "$err_msg"
        echo "echo '--|>'"
        echo "echo 'Grade :=>>$GRADE_MIN'"
    } > vpl_execution
    chmod +x vpl_execution
    exit 1
fi

# ============================================================================
# PASO 2: DETECTAR TOP ENTITY
# ============================================================================
log_info "==== PASO 2: TOP ENTITY ===="
get_source_files vhdl vhd
export TERM=dumb
get_first_source_file vhdl vhd
TOP_ENTITY=""
for SF in $SOURCE_FILES; do
    ghdl -c "$SF" &> /dev/null
    T="$(ghdl --find-top 2>/dev/null)"
    [ -n "$T" ] && { TOP_ENTITY="$T"; break; }
done
if [ -z "$TOP_ENTITY" ]; then
    TOP_ENTITY=${FIRST_SOURCE_FILE%.*}
    log_warn "Top no detectada, usando nombre archivo: $TOP_ENTITY"
fi
log_success "Top entity: $TOP_ENTITY"

# Localizar archivo de la top entity
get_source_files vhd vhdl NOERROR
TOP_FILE=""
SAVEIFS=$IFS; IFS=$'\n'
for F in $SOURCE_FILES; do
    if grep -qiE "entity[[:space:]]+${TOP_ENTITY}[[:space:]]+is" "$F" 2>/dev/null; then
        TOP_FILE="$F"; break
    fi
done
IFS=$SAVEIFS
[ -z "$TOP_FILE" ] && { log_error "No se encontró archivo de $TOP_ENTITY"; fail_with_min_grade ""; exit 1; }
log_info "Archivo top: $TOP_FILE"

# ============================================================================
# PASO 3: EXTRAER PUERTOS (preservando orden)
# ============================================================================
log_info "==== PASO 3: PUERTOS ===="

# Extrae el bloque port(...) completo (maneja paréntesis anidados y multi-línea)
# Devuelve UNA sola línea con todos los puertos separados por ';'
extract_port_block() {
    awk -v entity="$1" '
    BEGIN { ie=0; ip=0; depth=0; buf="" }
    {
        l = tolower($0)
        if (!ie && l ~ "entity[[:space:]]+"tolower(entity)"[[:space:]]+is") ie=1
        if (ie && !ip && l ~ /port[[:space:]]*\(/) {
            ip=1; depth=1
            sub(/.*[Pp][Oo][Rr][Tt][[:space:]]*\(/, "", $0)
        }
        if (ip) {
            line = $0
            n = length(line)
            for (i=1; i<=n; i++) {
                c = substr(line,i,1)
                if (c=="(") depth++
                else if (c==")") {
                    depth--
                    if (depth==0) {
                        buf = buf " " substr(line,1,i-1)
                        print buf
                        exit
                    }
                }
            }
            buf = buf " " line
        }
    }' "$2"
}

# Extrae el bloque generic(...) si existe (mismo patrón que port)
extract_generic_block() {
    awk -v entity="$1" '
    BEGIN { ie=0; ig=0; depth=0; buf=""; done=0 }
    {
        l = tolower($0)
        if (!ie && l ~ "entity[[:space:]]+"tolower(entity)"[[:space:]]+is") ie=1
        # parar si llegamos a port antes de encontrar generic
        if (ie && !ig && l ~ /port[[:space:]]*\(/) { exit }
        if (ie && !ig && l ~ /generic[[:space:]]*\(/) {
            ig=1; depth=1
            sub(/.*[Gg][Ee][Nn][Ee][Rr][Ii][Cc][[:space:]]*\(/, "", $0)
        }
        if (ig) {
            line = $0
            n = length(line)
            for (i=1; i<=n; i++) {
                c = substr(line,i,1)
                if (c=="(") depth++
                else if (c==")") {
                    depth--
                    if (depth==0) {
                        buf = buf " " substr(line,1,i-1)
                        print buf
                        exit
                    }
                }
            }
            buf = buf " " line
        }
    }' "$2"
}

# Convierte el bloque de puertos en una declaración por línea
# Maneja "A, B, C : in std_logic" expandiéndolo en 3 líneas
parse_ports() {
    local block="$1"
    # quitar comentarios VHDL "--..." al final de cada porción
    block=$(echo "$block" | sed 's/--[^"]*$//')
    # separar por ';' una declaración por línea
    echo "$block" | tr ';' '\n' | while IFS= read -r decl; do
        # decl ej: "  A, B, C : in std_logic"
        decl=$(echo "$decl" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$decl" ] && continue
        # separar nombres de tipo
        local names_part="${decl%%:*}"
        local rest="${decl#*:}"
        local dir=$(echo "$rest" | grep -ioE "^[[:space:]]*(in|out|inout|buffer)" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        local type=$(echo "$rest" | sed -E 's/^[[:space:]]*(in|out|inout|buffer)[[:space:]]+//I' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # Remover ":=" y valor por defecto si existe
        type=$(echo "$type" | sed 's/:=.*//' | sed 's/[[:space:]]*$//')
        # cada nombre separado por coma
        echo "$names_part" | tr ',' '\n' | while IFS= read -r nm; do
            nm=$(echo "$nm" | tr -d ' \t')
            [ -z "$nm" ] && continue
            echo "$nm|$dir|$type"
        done
    done
}

block=$(extract_port_block "$TOP_ENTITY" "$TOP_FILE")
[ -z "$block" ] && { log_error "No se pudo extraer port() de $TOP_ENTITY"; fail_with_min_grade ""; exit 1; }

# Extraer generics (si los hay). Formato esperado: "NAME : TYPE := VALUE; ..."
GENERIC_BLOCK=$(extract_generic_block "$TOP_ENTITY" "$TOP_FILE")
declare -A GENERIC_VALUES
GENERIC_HAS_DEFAULT=true
if [ -n "$GENERIC_BLOCK" ]; then
    log_info "Generics detectados, extrayendo..."
    # Parsear cada declaración separada por ';'
    while IFS= read -r decl; do
        decl=$(echo "$decl" | sed 's/--[^"]*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$decl" ] && continue
        # decl ej: "N : INTEGER := 12"
        gname=$(echo "$decl" | sed 's/[[:space:]]*:.*//' | tr -d ' ')
        gval=$(echo "$decl" | grep -oE ':=[[:space:]]*[^;]+' | sed 's/:=[[:space:]]*//' | sed 's/[[:space:]]*$//')
        if [ -z "$gval" ]; then
            log_warn "Generic '$gname' sin valor por defecto"
            GENERIC_HAS_DEFAULT=false
        else
            GENERIC_VALUES[$gname]="$gval"
            log_info "  $gname = $gval"
        fi
    done < <(echo "$GENERIC_BLOCK" | tr ';' '\n')
fi

# Sustituye nombres de generic por sus valores en una expresión de tipo
substitute_generics() {
    local s="$1"
    for gname in "${!GENERIC_VALUES[@]}"; do
        # Sustitución como palabra completa (case-insensitive sería ideal, pero
        # los generics suelen usarse en mayúsculas exactamente como se declaran)
        s=$(echo "$s" | sed -E "s/\b${gname}\b/${GENERIC_VALUES[$gname]}/g")
    done
    echo "$s"
}

while IFS='|' read -r nm dir type; do
    [ -z "$nm" ] && continue
    nm_lower=$(echo "$nm" | tr '[:upper:]' '[:lower:]')
    # Sustituir generics en el tipo
    type_resolved=$(substitute_generics "$type")
    PORT_DIR[$nm_lower]="$dir"
    PORT_TYPE[$nm_lower]="$type_resolved"
    PORT_ORIG[$nm_lower]="$nm"
    PORT_ORDER+=("$nm_lower")
    log_info "  $nm : $dir $type_resolved"
done < <(parse_ports "$block")

[ ${#PORT_DIR[@]} -eq 0 ] && { log_error "0 puertos extraídos"; fail_with_min_grade ""; exit 1; }
log_success "${#PORT_DIR[@]} puertos extraídos"

# ============================================================================
# PASO 4: DETECTAR/AUTO-DETECTAR CLOCK Y RESET, CARGAR CONFIG GLOBAL
# ============================================================================
log_info "==== PASO 4: CONFIGURACIÓN ===="

# Helper para extraer "clave = valor" del .cases (top-level, no dentro de case)
read_global_kv() {
    local key="$1"
    [ ! -f "$CASES_FILE" ] && return
    awk -v k="$key" '
        /^[[:space:]]*case[[:space:]]*=/ { incase=1 }
        !incase {
            if (match($0, "^[[:space:]]*"k"[[:space:]]*=")) {
                sub("^[[:space:]]*"k"[[:space:]]*=[[:space:]]*", "")
                sub(/[[:space:]]*#.*$/, "")
                sub(/[[:space:]]+$/, "")
                print
                exit
            }
        }' "$CASES_FILE"
}

# Cargar overrides globales
v=$(read_global_kv "stop_time_all"); [ -n "$v" ] && SIMULATION_STOP_TIME="$v"
v=$(read_global_kv "clock");         [ -n "$v" ] && CLK_SIGNAL="$v"
v=$(read_global_kv "clock_period");  [ -n "$v" ] && CLK_PERIOD="$v"
v=$(read_global_kv "reset");         [ -n "$v" ] && RESET_SIGNAL="$v"
v=$(read_global_kv "reset_active");  [ -n "$v" ] && RESET_ACTIVE="$v"
v=$(read_global_kv "reset_type");    [ -n "$v" ] && RESET_TYPE="$v"
v=$(read_global_kv "reset_cycles");  [ -n "$v" ] && RESET_CYCLES="$v"
v=$(read_global_kv "stop_time_default"); [ -n "$v" ] && GLOBAL_CASE_STOP="$v"

# Auto-detect clock (si no se especificó)
if [ -z "$CLK_SIGNAL" ]; then
    for p in "${PORT_ORDER[@]}"; do
        if [[ "$p" == "clk" || "$p" == "clock" || "$p" == "ck" ]]; then
            CLK_SIGNAL="${PORT_ORIG[$p]}"; break
        fi
    done
fi

# Validar clock contra puertos
if [ -n "$CLK_SIGNAL" ]; then
    clk_lower=$(echo "$CLK_SIGNAL" | tr '[:upper:]' '[:lower:]')
    if [ -z "${PORT_DIR[$clk_lower]}" ]; then
        log_warn "Clock '$CLK_SIGNAL' no es puerto. Buscando candidato..."
        CLK_SIGNAL=""
        for p in "${PORT_ORDER[@]}"; do
            if [[ "$p" == *"clk"* || "$p" == *"clock"* ]]; then
                CLK_SIGNAL="${PORT_ORIG[$p]}"; break
            fi
        done
    fi
fi

# Decidir EVAL_MODE: si hay clock detectado => SEQUENTIAL
if [ -n "$CLK_SIGNAL" ]; then
    EVAL_MODE="SEQUENTIAL"
fi

# Auto-detect reset (solo si modo secuencial y no se especificó)
if [ "$EVAL_MODE" = "SEQUENTIAL" ] && [ -z "$RESET_SIGNAL" ]; then
    for cand in reset rst clr reset_n rst_n clear; do
        if [ -n "${PORT_DIR[$cand]}" ]; then
            RESET_SIGNAL="${PORT_ORIG[$cand]}"
            # Heurística polaridad: nombres con _n => activo bajo
            if [[ "$cand" == *"_n" ]]; then RESET_ACTIVE="0"; fi
            break
        fi
    done
fi

# Validar reset
if [ -n "$RESET_SIGNAL" ]; then
    rst_lower=$(echo "$RESET_SIGNAL" | tr '[:upper:]' '[:lower:]')
    if [ -z "${PORT_DIR[$rst_lower]}" ]; then
        log_warn "Reset '$RESET_SIGNAL' no es puerto. Ignorando."
        RESET_SIGNAL=""
    fi
fi

log_info "Modo:           $EVAL_MODE"
log_info "Clock:          ${CLK_SIGNAL:-<ninguno>}"
log_info "Clock period:   $CLK_PERIOD"
log_info "Reset:          ${RESET_SIGNAL:-<ninguno>}"
log_info "Reset active:   $RESET_ACTIVE ($([ "$RESET_ACTIVE" = "1" ] && echo high || echo low))"
log_info "Reset type:     $RESET_TYPE"
log_info "Reset cycles:   $RESET_CYCLES"
log_info "Stop sim:       $SIMULATION_STOP_TIME"

# ============================================================================
# PASO 5: PARSEAR CASOS
# ============================================================================
log_info "==== PASO 5: CASOS ===="

current_case=""
current_stop=""
current_grade=""
current_inputs=""
current_outputs=""
current_is_seq=false
section=""

save_case() {
    if [ -n "$current_case" ]; then
        CASE_NAMES+=("$current_case")
        CASE_STOP_TIMES+=("${current_stop:-$GLOBAL_CASE_STOP}")
        CASE_GRADE_REDUCTIONS+=("$current_grade")
        CASE_INPUTS+=("$current_inputs")
        CASE_OUTPUTS+=("$current_outputs")
        CASE_IS_SEQUENTIAL+=("$current_is_seq")
    fi
}

is_array_value() {
    [[ "$1" =~ ^\[.*\]$ ]] && echo "true" || echo "false"
}

[ ! -f "$CASES_FILE" ] && { log_error "No existe $CASES_FILE"; fail_with_min_grade ""; exit 1; }

while IFS= read -r raw; do
    line=$(echo "$raw" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    lower=$(echo "$line" | tr '[:upper:]' '[:lower:]')

    # Saltar directivas globales (ya leídas)
    case "$lower" in
        stop_time_all*|clock=*|clock\ *=*|clock_period*|reset=*|reset\ *=*|reset_active*|reset_type*|reset_cycles*|stop_time_default*)
            [ -z "$current_case" ] && continue ;;
    esac

    if [[ "$lower" =~ ^case[[:space:]]*= ]]; then
        save_case
        current_case=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        current_stop=""; current_grade=""; current_inputs=""; current_outputs=""
        current_is_seq=false; section=""
        log_info "Caso: $current_case"
        continue
    fi
    [ -z "$current_case" ] && continue

    if [[ "$lower" =~ ^stop_time[[:space:]]*= ]]; then
        current_stop=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        continue
    fi
    if [[ "$lower" =~ ^grade[[:space:]] ]]; then
        current_grade=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        continue
    fi
    if [[ "$lower" =~ ^cycles[[:space:]]*= ]]; then
        # cycles forza modo secuencial para ese caso (informativo)
        current_is_seq=true
        continue
    fi

    case "$lower" in
        input:*)  section="input";  continue ;;
        output:*) section="output"; continue ;;
    esac

    # signal = valor
    if [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*= ]]; then
        sig=$(echo "$line" | cut -d= -f1 | sed 's/[[:space:]]//g')
        val=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ "$section" = "input" ]; then
            current_inputs="${current_inputs}${sig}=${val}|"
            [ "$(is_array_value "$val")" = "true" ] && current_is_seq=true
        elif [ "$section" = "output" ]; then
            current_outputs="${current_outputs}${sig}=${val}|"
            [ "$(is_array_value "$val")" = "true" ] && current_is_seq=true
        fi
    fi
done < "$CASES_FILE"
save_case

TOTAL_CASES=${#CASE_NAMES[@]}
[ $TOTAL_CASES -eq 0 ] && { log_error "0 casos en $CASES_FILE"; fail_with_min_grade ""; exit 1; }
log_success "$TOTAL_CASES casos parseados"

# ============================================================================
# PASO 6: HELPERS PARA FORMATEO VHDL
# ============================================================================

# Formatea un valor para asignación VHDL (no para assert)
# $1 = valor, $2 = es vector? (true/false)
# Devuelve: "valor formateado" listo para <= o = en VHDL
format_vhdl_value() {
    local v="$1"
    local is_vec="$2"
    v=$(echo "$v" | sed 's/[[:space:]]//g')
    if [ "$is_vec" = "true" ]; then
        if [[ "$v" =~ ^[01XU\-]+$ ]]; then
            echo "\"$v\""
        elif [[ "$v" =~ ^0x[0-9A-Fa-f]+$ ]]; then
            echo "x\"${v#0x}\""
        else
            echo "$v"
        fi
    else
        if [[ "$v" =~ ^[01XU\-]$ ]]; then
            echo "'$v'"
        else
            echo "$v"
        fi
    fi
}

# ¿El puerto es vector? (case-insensitive)
is_vector_port() {
    local sig="$1"
    local t=$(echo "${PORT_TYPE[$sig]}" | tr '[:upper:]' '[:lower:]')
    [[ "$t" == *vector* ]]
}

# Cuenta elementos de un array "[a, b, c]" -> 3
array_length() {
    local v="$1"
    v="${v#[}"; v="${v%]}"
    echo "$v" | tr ',' '\n' | grep -c .
}

# Devuelve el i-ésimo elemento (1-indexed) de un array "[a, b, c]"
array_at() {
    local v="$1"; local idx="$2"
    v="${v#[}"; v="${v%]}"
    echo "$v" | tr ',' '\n' | sed -n "${idx}p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ============================================================================
# PASO 7: GENERAR TESTBENCH
# ============================================================================
log_info "==== PASO 7: TESTBENCH ===="

# Convierte CLK_PERIOD ("10 ns") a número y unidad por separado
clk_num=$(echo "$CLK_PERIOD" | grep -oE '^[0-9.]+')
clk_unit=$(echo "$CLK_PERIOD" | grep -oE '[a-zA-Z]+$')
clk_half_num=$(echo "scale=4; $clk_num / 2" | bc | sed 's/^\./0./')

# Para reset, valor activo e inactivo en VHDL
if [ "$RESET_ACTIVE" = "1" ]; then
    RESET_ACTIVE_VAL="'1'"; RESET_INACTIVE_VAL="'0'"
else
    RESET_ACTIVE_VAL="'0'"; RESET_INACTIVE_VAL="'1'"
fi

# Lower-case helpers para clock y reset
clk_lower=""; rst_lower=""
[ -n "$CLK_SIGNAL"   ] && clk_lower=$(echo "$CLK_SIGNAL"   | tr '[:upper:]' '[:lower:]')
[ -n "$RESET_SIGNAL" ] && rst_lower=$(echo "$RESET_SIGNAL" | tr '[:upper:]' '[:lower:]')

# Genera el TB en un solo flujo
{
echo "-- ============================================================================"
echo "-- AUTO-GENERATED TESTBENCH (VPL VHDL Evaluator v3.0)"
echo "-- Mode: $EVAL_MODE | Clock: ${CLK_SIGNAL:-N/A} | Reset: ${RESET_SIGNAL:-N/A}"
echo "-- ============================================================================"
echo "library IEEE;"
echo "use IEEE.STD_LOGIC_1164.ALL;"
echo "use IEEE.NUMERIC_STD.ALL;"
echo ""
echo "entity $TB_ENTITY is end $TB_ENTITY;"
echo ""
echo "architecture tb of $TB_ENTITY is"
echo ""

# Component (en el orden original)
echo "    component $TOP_ENTITY"
echo "    port ("
first=true
for p in "${PORT_ORDER[@]}"; do
    sep=";"; [ "$first" = true ] && { sep=""; first=false; }
    echo "        $sep ${PORT_ORIG[$p]} : ${PORT_DIR[$p]} ${PORT_TYPE[$p]}"
done
echo "    );"
echo "    end component;"
echo ""

# Señales tb_*
for p in "${PORT_ORDER[@]}"; do
    type_lower=$(echo "${PORT_TYPE[$p]}" | tr '[:upper:]' '[:lower:]')
    if [ "${PORT_DIR[$p]}" = "in" ]; then
        if [[ "$type_lower" == *vector* ]]; then
            echo "    signal tb_${p} : ${PORT_TYPE[$p]} := (others => '0');"
        else
            echo "    signal tb_${p} : ${PORT_TYPE[$p]} := '0';"
        fi
    else
        echo "    signal tb_${p} : ${PORT_TYPE[$p]};"
    fi
done
echo "    signal sim_done : boolean := false;"
echo ""
echo "begin"
echo ""

# Instancia DUT (port map en orden)
echo "    dut: $TOP_ENTITY port map ("
first=true
for p in "${PORT_ORDER[@]}"; do
    sep=","; [ "$first" = true ] && { sep=""; first=false; }
    echo "        $sep ${PORT_ORIG[$p]} => tb_${p}"
done
echo "    );"
echo ""

# Generador de reloj (solo si secuencial)
if [ "$EVAL_MODE" = "SEQUENTIAL" ] && [ -n "$clk_lower" ]; then
    echo "    -- Clock: período completo = $CLK_PERIOD"
    echo "    clk_gen: process"
    echo "    begin"
    echo "        while not sim_done loop"
    echo "            tb_${clk_lower} <= '0';"
    echo "            wait for $clk_half_num $clk_unit;"
    echo "            tb_${clk_lower} <= '1';"
    echo "            wait for $clk_half_num $clk_unit;"
    echo "        end loop;"
    echo "        wait;"
    echo "    end process clk_gen;"
    echo ""
fi

# === STIMULUS PROCESS ===
echo "    stim_proc: process"
echo "    begin"

if [ "$EVAL_MODE" = "SEQUENTIAL" ]; then
    # Aplicar reset al inicio. NO sincronizar después: el primer flanco lo
    # consume el primer 'wait until rising_edge' del primer ciclo.
    if [ -n "$rst_lower" ]; then
        echo "        -- Aplicar reset ($RESET_TYPE, activo=$RESET_ACTIVE)"
        echo "        tb_${rst_lower} <= $RESET_ACTIVE_VAL;"
        if [ "$RESET_TYPE" = "sync" ]; then
            # Reset síncrono: asegurar N rising_edges con reset activo,
            # luego liberar entre flancos para evitar race con el siguiente edge.
            echo "        for i in 1 to $RESET_CYCLES loop"
            echo "            wait until rising_edge(tb_${clk_lower});"
            echo "        end loop;"
            echo "        wait for 1 ns;"
            echo "        tb_${rst_lower} <= $RESET_INACTIVE_VAL;"
        else
            # Reset asíncrono: tiempo fijo, se libera en cualquier punto.
            echo "        wait for $((RESET_CYCLES))*$CLK_PERIOD;"
            echo "        tb_${rst_lower} <= $RESET_INACTIVE_VAL;"
        fi
        echo ""
    fi
fi

# Por cada caso
for ((i=0; i<TOTAL_CASES; i++)); do
    cname="${CASE_NAMES[$i]}"
    is_seq="${CASE_IS_SEQUENTIAL[$i]}"
    cstop="${CASE_STOP_TIMES[$i]}"
    
    echo "        -- ============================================"
    echo "        -- CASO: $cname"
    echo "        -- ============================================"
    echo "        report \"BEGIN:${cname}\" severity note;"
    
    # Si el modo global es secuencial PERO el caso no usa arrays, igualmente
    # sincronizamos por flanco. Si modo global es combinatorio, usamos wait for.
    if [ "$EVAL_MODE" = "SEQUENTIAL" ]; then
        # ¿Caso multi-ciclo (con arrays)?
        max_cycles=1
        IFS='|' read -ra inputs <<< "${CASE_INPUTS[$i]}"
        for pair in "${inputs[@]}"; do
            [ -z "$pair" ] && continue
            val="${pair#*=}"
            if [[ "$val" =~ ^\[.*\]$ ]]; then
                len=$(array_length "$val")
                [ $len -gt $max_cycles ] && max_cycles=$len
            fi
        done
        IFS='|' read -ra outputs <<< "${CASE_OUTPUTS[$i]}"
        for pair in "${outputs[@]}"; do
            [ -z "$pair" ] && continue
            val="${pair#*=}"
            if [[ "$val" =~ ^\[.*\]$ ]]; then
                len=$(array_length "$val")
                [ $len -gt $max_cycles ] && max_cycles=$len
            fi
        done
        
        # Asignar inputs ciclo a ciclo
        for ((c=1; c<=max_cycles; c++)); do
            echo "        -- ciclo $c"
            for pair in "${inputs[@]}"; do
                [ -z "$pair" ] && continue
                sig="${pair%%=*}"
                val="${pair#*=}"
                sig_lower=$(echo "$sig" | tr '[:upper:]' '[:lower:]')
                # No tocar el reloj desde el caso (lo controla clk_gen)
                [ "$sig_lower" = "$clk_lower" ] && continue
                # El reset SÍ se puede reasignar desde un caso si el profesor quiere
                
                is_vec=false; is_vector_port "$sig_lower" && is_vec=true
                
                if [[ "$val" =~ ^\[.*\]$ ]]; then
                    elem=$(array_at "$val" $c)
                    [ -z "$elem" ] && continue
                    [ "$elem" = "_" ] && continue
                    fmt=$(format_vhdl_value "$elem" "$is_vec")
                    echo "        tb_${sig_lower} <= ${fmt};"
                else
                    # Solo el primer ciclo, valor constante
                    if [ "$c" = "1" ]; then
                        fmt=$(format_vhdl_value "$val" "$is_vec")
                        echo "        tb_${sig_lower} <= ${fmt};"
                    fi
                fi
            done
            
            # Esperar al flanco activo
            echo "        wait until rising_edge(tb_${clk_lower});"
            # delta para que outputs se estabilicen
            echo "        wait for 1 ns;"
            
            # Verificar outputs en este ciclo
            for pair in "${outputs[@]}"; do
                [ -z "$pair" ] && continue
                sig="${pair%%=*}"
                val="${pair#*=}"
                sig_lower=$(echo "$sig" | tr '[:upper:]' '[:lower:]')
                is_vec=false; is_vector_port "$sig_lower" && is_vec=true
                
                if [[ "$val" =~ ^\[.*\]$ ]]; then
                    elem=$(array_at "$val" $c)
                    [ -z "$elem" ] && continue
                    [ "$elem" = "_" ] && continue
                    fmt=$(format_vhdl_value "$elem" "$is_vec")
                    echo "        assert tb_${sig_lower} = ${fmt}"
                    echo "            report \"FAIL:${cname}:${sig}:cycle_${c}\" severity error;"
                else
                    # Valor escalar: solo verificar en el último ciclo
                    if [ "$c" = "$max_cycles" ]; then
                        fmt=$(format_vhdl_value "$val" "$is_vec")
                        echo "        assert tb_${sig_lower} = ${fmt}"
                        echo "            report \"FAIL:${cname}:${sig}\" severity error;"
                    fi
                fi
            done
        done
    else
        # MODO COMBINATORIAL
        IFS='|' read -ra inputs <<< "${CASE_INPUTS[$i]}"
        for pair in "${inputs[@]}"; do
            [ -z "$pair" ] && continue
            sig="${pair%%=*}"
            val="${pair#*=}"
            sig_lower=$(echo "$sig" | tr '[:upper:]' '[:lower:]')
            is_vec=false; is_vector_port "$sig_lower" && is_vec=true
            fmt=$(format_vhdl_value "$val" "$is_vec")
            echo "        tb_${sig_lower} <= ${fmt};"
        done
        echo "        wait for $cstop;"
        IFS='|' read -ra outputs <<< "${CASE_OUTPUTS[$i]}"
        for pair in "${outputs[@]}"; do
            [ -z "$pair" ] && continue
            sig="${pair%%=*}"
            val="${pair#*=}"
            sig_lower=$(echo "$sig" | tr '[:upper:]' '[:lower:]')
            is_vec=false; is_vector_port "$sig_lower" && is_vec=true
            fmt=$(format_vhdl_value "$val" "$is_vec")
            echo "        assert tb_${sig_lower} = ${fmt}"
            echo "            report \"FAIL:${cname}:${sig}\" severity error;"
        done
    fi
    
    echo "        report \"DONE:${cname}\" severity note;"
    echo ""
done

echo "        sim_done <= true;"
echo "        wait;"
echo "    end process stim_proc;"
echo ""
echo "end tb;"
} > "$GENERATED_TB"

[ $? -ne 0 ] && { log_error "Falló generación de TB"; fail_with_min_grade ""; exit 1; }
log_success "TB generado: $GENERATED_TB"

# ============================================================================
# PASO 8: COMPILAR Y SIMULAR
# ============================================================================
log_info "==== PASO 8: COMPILACIÓN+SIMULACIÓN ===="

ghdl -a --std=08 "$GENERATED_TB" 2>&1
[ $? -ne 0 ] && { log_error "Error compilando TB"; cat "$GENERATED_TB" | head -80; fail_with_min_grade ""; exit 1; }

ghdl -e --std=08 "$TB_ENTITY" 2>&1
[ $? -ne 0 ] && { log_error "Error elaborando TB"; fail_with_min_grade ""; exit 1; }

SIM_STOP_NOSPACE=$(echo "$SIMULATION_STOP_TIME" | tr -d ' ')
log_info "Simulando con stop-time=$SIM_STOP_NOSPACE"
SIM_OUTPUT=$(ghdl -r --std=08 "$TB_ENTITY" --stop-time="$SIM_STOP_NOSPACE" 2>&1)

# ============================================================================
# PASO 9: EVALUAR RESULTADOS
# ============================================================================
log_info "==== PASO 9: EVALUACIÓN ===="

grade=$GRADE_MAX
comments=""
passed=0; failed=0

for ((i=0; i<TOTAL_CASES; i++)); do
    cname="${CASE_NAMES[$i]}"
    gred="${CASE_GRADE_REDUCTIONS[$i]}"

    fail_lines=$(echo "$SIM_OUTPUT" | grep "FAIL:${cname}:" | sort -u)
    
    if [ -z "$fail_lines" ] && echo "$SIM_OUTPUT" | grep -q "DONE:${cname}"; then
        log_success "PASS: $cname"
        ((passed++))
    else
        log_error "FAIL: $cname"
        ((failed++))
        if [ -n "$gred" ]; then
            if echo "$gred" | grep -q "%"; then
                pct=$(echo "$gred" | tr -d '%')
                reduction=$(echo "scale=4; ($GRADE_MAX - $GRADE_MIN) * $pct / 100" | bc)
            else
                reduction="$gred"
            fi
        else
            reduction=$(echo "scale=4; ($GRADE_MAX - $GRADE_MIN) / $TOTAL_CASES" | bc)
        fi
        grade=$(echo "scale=4; $grade - $reduction" | bc)
        (( $(echo "$grade < $GRADE_MIN" | bc -l) )) && grade=$GRADE_MIN
        
        comments="${comments}<|--\n-FAIL: ${cname}\n"
        # Detalle por señal
        if [ -n "$fail_lines" ]; then
            comments="${comments}Detalles:\n"
            while IFS= read -r ln; do
                # ln típicamente: ".../some.vhd:NN:CC:@TIME:(report note): FAIL:caso:senal:cycle_N"
                msg=$(echo "$ln" | sed 's/.*FAIL:/FAIL:/')
                comments="${comments}  - ${msg}\n"
            done <<< "$fail_lines"
        else
            comments="${comments}(simulación no completó este caso)\n"
        fi
        comments="${comments}--|>\n"
    fi
done

grade_fmt=$(printf "%.2f" $grade | sed 's/\.00$//')

log_success "================================"
log_success "Casos:   $passed/$TOTAL_CASES"
log_success "Nota:    $grade_fmt / $GRADE_MAX"
log_success "================================"

# ============================================================================
# PASO 10: GENERAR vpl_execution
# ============================================================================
{
    echo "#!/bin/bash"
    echo "echo"
    echo "echo '<|--'"
    echo "echo '-Evaluación VHDL ($EVAL_MODE)'"
    echo "echo '>+----------------------------------+'"
    echo "echo '>| Modo            : $EVAL_MODE'"
    echo "echo '>| Casos totales   : $TOTAL_CASES'"
    echo "echo '>| Casos correctos : $passed'"
    echo "echo '>| Casos fallidos  : $failed'"
    echo "echo '>+----------------------------------+'"
    echo "echo '--|>'"
    [ -n "$comments" ] && echo "printf '$comments'"
    echo "echo"
    echo "echo 'Grade :=>>$grade_fmt'"
} > vpl_execution
chmod +x vpl_execution

log_success "Listo. Resultado en vpl_execution"
# rm -f "$GENERATED_TB"