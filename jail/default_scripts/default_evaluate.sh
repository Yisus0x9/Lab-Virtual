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
. vpl_vhdl_lib.sh


# ============================================================================
# CONFIGURACIÓN
# ============================================================================
CASES_FILE="vpl_evaluate.cases"
GENERATED_TB="__vpl_tb_generated.vhd"
TB_ENTITY="vpl_tb_generated"

GRADE_MIN=${VPL_GRADEMIN:-0}
GRADE_MAX=${VPL_GRADEMAX:-10}

SIMULATION_STOP_TIME="1ms"
CLK_SIGNAL=""
CLK_PERIOD="10 ns"
RESET_SIGNAL=""
RESET_ACTIVE="1"
RESET_TYPE="async"
RESET_CYCLES="2"
GLOBAL_CASE_STOP="50 ns"

EVAL_MODE="COMBINATORIAL"

CASE_NAMES=()
CASE_STOP_TIMES=()
CASE_GRADE_REDUCTIONS=()
CASE_INPUTS=()
CASE_OUTPUTS=()
CASE_IS_SEQUENTIAL=()

declare -A PORT_DIR
declare -A PORT_TYPE
declare -A PORT_ORIG
PORT_ORDER=()

TOTAL_CASES=0

# ============================================================================
# PASO 1: COMPILAR FUENTES DEL ALUMNO
# ============================================================================
./vpl_run.sh
if [ $? -ne 0 ]; then
    log_error "Falló la compilación del código del alumno."
    err_msg=$(cat vpl_compilation_error.txt 2>/dev/null)
    {
        echo "#!/bin/bash"
        echo "echo"
        echo "echo '<|--'"
        echo "echo '-Error de compilación'"
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
get_source_files vhdl vhd NOERROR
export TERM=dumb

# Verificar que existen archivos VHDL antes de continuar
if [ -z "$SOURCE_FILES" ]; then
    fail_with_min_grade "No se encontraron archivos VHDL (.vhd/.vhdl) en la entrega.
El alumno debe subir al menos un archivo con la entidad a evaluar."
    exit 1
fi

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

TOP_FILE=""
SAVEIFS=$IFS; IFS=$'\n'
for F in $SOURCE_FILES; do
    if grep -qiE "entity[[:space:]]+${TOP_ENTITY}[[:space:]]+is" "$F" 2>/dev/null; then
        TOP_FILE="$F"; break
    fi
done
IFS=$SAVEIFS
if [ -z "$TOP_FILE" ]; then
    # Fallback: usar el primer archivo disponible
    TOP_FILE=$(echo "$SOURCE_FILES" | head -1)
    log_warn "Entidad '$TOP_ENTITY' no encontrada explícitamente. Usando: $TOP_FILE"
fi
log_info "Archivo top: $TOP_FILE"

# ============================================================================
# PASO 3: EXTRAER PUERTOS
# ============================================================================
block=$(extract_port_block "$TOP_ENTITY" "$TOP_FILE")
[ -z "$block" ] && { log_error "No se pudo extraer port() de $TOP_ENTITY"; fail_with_min_grade ""; exit 1; }

GENERIC_BLOCK=$(extract_generic_block "$TOP_ENTITY" "$TOP_FILE")
declare -A GENERIC_VALUES
GENERIC_HAS_DEFAULT=true
if [ -n "$GENERIC_BLOCK" ]; then
    while IFS= read -r decl; do
        decl=$(echo "$decl" | sed 's/--[^"]*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$decl" ] && continue
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

while IFS='|' read -r nm dir type; do
    [ -z "$nm" ] && continue
    nm_lower=$(echo "$nm" | tr '[:upper:]' '[:lower:]')
    type_resolved=$(substitute_generics "$type")
    PORT_DIR[$nm_lower]="$dir"
    PORT_TYPE[$nm_lower]="$type_resolved"
    PORT_ORIG[$nm_lower]="$nm"
    PORT_ORDER+=("$nm_lower")
done < <(parse_ports "$block")

[ ${#PORT_DIR[@]} -eq 0 ] && { log_error "0 puertos extraídos"; fail_with_min_grade ""; exit 1; }
log_success "${#PORT_DIR[@]} puertos extraídos"

# ============================================================================
# PASO 4: DETECTAR CLOCK Y RESET, CARGAR CONFIG GLOBAL
# ============================================================================
v=$(read_global_kv "stop_time_all");     [ -n "$v" ] && SIMULATION_STOP_TIME="$v"
v=$(read_global_kv "clock");             [ -n "$v" ] && CLK_SIGNAL="$v"
v=$(read_global_kv "clock_period");      [ -n "$v" ] && CLK_PERIOD="$v"
v=$(read_global_kv "reset");             [ -n "$v" ] && RESET_SIGNAL="$v"
v=$(read_global_kv "reset_active");      [ -n "$v" ] && RESET_ACTIVE="$v"
v=$(read_global_kv "reset_type");        [ -n "$v" ] && RESET_TYPE="$v"
v=$(read_global_kv "reset_cycles");      [ -n "$v" ] && RESET_CYCLES="$v"
v=$(read_global_kv "stop_time_default"); [ -n "$v" ] && GLOBAL_CASE_STOP="$v"

if [ -z "$CLK_SIGNAL" ]; then
    for p in "${PORT_ORDER[@]}"; do
        if [[ "$p" == "clk" || "$p" == "clock" || "$p" == "ck" ]]; then
            CLK_SIGNAL="${PORT_ORIG[$p]}"; break
        fi
    done
fi

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

[ -n "$CLK_SIGNAL" ] && EVAL_MODE="SEQUENTIAL"

if [ "$EVAL_MODE" = "SEQUENTIAL" ] && [ -z "$RESET_SIGNAL" ]; then
    for cand in reset rst clr reset_n rst_n clear; do
        if [ -n "${PORT_DIR[$cand]}" ]; then
            RESET_SIGNAL="${PORT_ORIG[$cand]}"
            [[ "$cand" == *"_n" ]] && RESET_ACTIVE="0"
            break
        fi
    done
fi

if [ -n "$RESET_SIGNAL" ]; then
    rst_lower=$(echo "$RESET_SIGNAL" | tr '[:upper:]' '[:lower:]')
    if [ -z "${PORT_DIR[$rst_lower]}" ]; then
        log_warn "Reset '$RESET_SIGNAL' no es puerto. Ignorando."
        RESET_SIGNAL=""
    fi
fi

log_info "Modo: $EVAL_MODE | Clock: ${CLK_SIGNAL:-<ninguno>} | Reset: ${RESET_SIGNAL:-<ninguno>} | Stop: $SIMULATION_STOP_TIME"

# ============================================================================
# PASO 5: PARSEAR CASOS
# ============================================================================
current_case=""
current_stop=""
current_grade=""
current_inputs=""
current_outputs=""
current_is_seq=false
section=""

[ ! -f "$CASES_FILE" ] && { log_error "No existe $CASES_FILE"; fail_with_min_grade ""; exit 1; }

while IFS= read -r raw; do
    line=$(echo "$raw" | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    lower=$(echo "$line" | tr '[:upper:]' '[:lower:]')

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
        current_stop=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); continue
    fi
    if [[ "$lower" =~ ^grade[[:space:]] ]]; then
        current_grade=$(echo "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); continue
    fi
    if [[ "$lower" =~ ^cycles[[:space:]]*= ]]; then
        current_is_seq=true; continue
    fi

    case "$lower" in
        input:*)  section="input";  continue ;;
        output:*) section="output"; continue ;;
    esac

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
# PASO 6: PREPARAR VARIABLES PARA EL TESTBENCH
# ============================================================================

clk_num=$(echo "$CLK_PERIOD" | grep -oE '^[0-9.]+')
clk_unit=$(echo "$CLK_PERIOD" | grep -oE '[a-zA-Z]+$')
clk_half_num=$(echo "scale=4; $clk_num / 2" | bc | sed 's/^\./0./')

if [ "$RESET_ACTIVE" = "1" ]; then
    RESET_ACTIVE_VAL="'1'"; RESET_INACTIVE_VAL="'0'"
else
    RESET_ACTIVE_VAL="'0'"; RESET_INACTIVE_VAL="'1'"
fi

clk_lower=""; rst_lower=""
[ -n "$CLK_SIGNAL"   ] && clk_lower=$(echo "$CLK_SIGNAL"   | tr '[:upper:]' '[:lower:]')
[ -n "$RESET_SIGNAL" ] && rst_lower=$(echo "$RESET_SIGNAL" | tr '[:upper:]' '[:lower:]')

# ============================================================================
# PASO 7: GENERAR TESTBENCH
# ============================================================================
generate_testbench "$GENERATED_TB"
[ $? -ne 0 ] && { log_error "Falló generación de TB"; fail_with_min_grade ""; exit 1; }

# ============================================================================
# PASO 8: COMPILAR Y SIMULAR
# ============================================================================
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
        (( $(echo "$grade > $GRADE_MAX" | bc -l) )) && grade=$GRADE_MAX

        comments="${comments}<|--\n-FAIL: ${cname}\n"
        if [ -n "$fail_lines" ]; then
            comments="${comments}Detalles:\n"
            while IFS= read -r ln; do
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
write_vpl_execution "$grade_fmt" "$EVAL_MODE" "$TOTAL_CASES" "$passed" "$failed" "$comments"
log_success "Listo. Resultado en vpl_execution"
