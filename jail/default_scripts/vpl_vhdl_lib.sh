#!/bin/bash
# This file is part of VPL for Moodle
# VPL VHDL Evaluator Library v3.0
# Copyright (C) 2014 onwards Juan Carlos Rodríguez-del-Pino
# License http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
# Author Jesus Peñarrieta Villa
#
# Funciones auxiliares para default_evaluate.sh
# Cargar con: . vpl_vhdl_lib.sh

# ============================================================================
# LOGGING
# ============================================================================

log_info()    { echo "-INFO:=>  $*"; }
log_error()   { echo "-ERROR:=> $*"; }
log_success() { echo "-SUCCESS:> $*"; }
log_warn()    { echo "-WARN:=>  $*"; }

# ============================================================================
# FALLO CON NOTA MÍNIMA
# ============================================================================

# Escribe vpl_execution con grade mínimo y mensaje opcional
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
# EXTRACCIÓN DE PUERTOS
# ============================================================================

# Extrae el bloque port(...) completo (maneja paréntesis anidados y multi-línea)
# $1=nombre entidad, $2=archivo fuente
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
# $1=nombre entidad, $2=archivo fuente
extract_generic_block() {
    awk -v entity="$1" '
    BEGIN { ie=0; ig=0; depth=0; buf=""; done=0 }
    {
        l = tolower($0)
        if (!ie && l ~ "entity[[:space:]]+"tolower(entity)"[[:space:]]+is") ie=1
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

# Convierte el bloque de puertos en líneas "nombre|dir|tipo"
# Maneja "A, B, C : in std_logic" expandiéndolo en 3 líneas
parse_ports() {
    local block="$1"
    block=$(echo "$block" | sed 's/--[^"]*$//')
    echo "$block" | tr ';' '\n' | while IFS= read -r decl; do
        decl=$(echo "$decl" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$decl" ] && continue
        local names_part="${decl%%:*}"
        local rest="${decl#*:}"
        local dir=$(echo "$rest" | grep -ioE "^[[:space:]]*(in|out|inout|buffer)" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        local type=$(echo "$rest" | sed -E 's/^[[:space:]]*(in|out|inout|buffer)[[:space:]]+//I' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        type=$(echo "$type" | sed 's/:=.*//' | sed 's/[[:space:]]*$//')
        echo "$names_part" | tr ',' '\n' | while IFS= read -r nm; do
            nm=$(echo "$nm" | tr -d ' \t')
            [ -z "$nm" ] && continue
            echo "$nm|$dir|$type"
        done
    done
}

# Sustituye nombres de generic por sus valores en una expresión de tipo
# Usa el array global GENERIC_VALUES
substitute_generics() {
    local s="$1"
    for gname in "${!GENERIC_VALUES[@]}"; do
        s=$(echo "$s" | sed -E "s/\b${gname}\b/${GENERIC_VALUES[$gname]}/g")
    done
    echo "$s"
}

# ============================================================================
# LECTURA DE CONFIGURACIÓN GLOBAL DEL .CASES
# ============================================================================

# Extrae "clave = valor" del .cases (solo sección global, no dentro de case)
# Usa la variable global CASES_FILE
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

# ============================================================================
# PARSEO DE CASOS
# ============================================================================

# Guarda el caso actual en los arrays globales CASE_*
# Usa variables globales: current_case, current_stop, current_grade,
#                         current_inputs, current_outputs, current_is_seq
#                         GLOBAL_CASE_STOP
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

# Devuelve "true" si el valor tiene formato de array "[...]"
is_array_value() {
    [[ "$1" =~ ^\[.*\]$ ]] && echo "true" || echo "false"
}

# ============================================================================
# HELPERS VHDL
# ============================================================================

# Formatea un valor para asignación VHDL
# $1=valor, $2=es vector? (true/false)
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

# Devuelve true si el puerto es vector (usa PORT_TYPE global)
is_vector_port() {
    local sig="$1"
    local t=$(echo "${PORT_TYPE[$sig]}" | tr '[:upper:]' '[:lower:]')
    [[ "$t" == *vector* ]]
}

# Cuenta elementos de un array "[a, b, c]" → 3
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
# GENERACIÓN DEL TESTBENCH
# ============================================================================

# Genera el testbench VHDL en el archivo $1
# Usa globales: EVAL_MODE, CLK_SIGNAL, RESET_SIGNAL, CLK_PERIOD,
#               RESET_ACTIVE, RESET_ACTIVE_VAL, RESET_INACTIVE_VAL,
#               RESET_TYPE, RESET_CYCLES, clk_lower, rst_lower,
#               clk_half_num, clk_unit, PORT_ORDER, PORT_DIR, PORT_TYPE,
#               PORT_ORIG, TOP_ENTITY, TB_ENTITY,
#               TOTAL_CASES, CASE_NAMES, CASE_IS_SEQUENTIAL,
#               CASE_STOP_TIMES, CASE_INPUTS, CASE_OUTPUTS
generate_testbench() {
    local out_file="$1"
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

    echo "    component $TOP_ENTITY"
    echo "    port ("
    local first=true
    for p in "${PORT_ORDER[@]}"; do
        local sep=";"; [ "$first" = true ] && { sep=""; first=false; }
        echo "        $sep ${PORT_ORIG[$p]} : ${PORT_DIR[$p]} ${PORT_TYPE[$p]}"
    done
    echo "    );"
    echo "    end component;"
    echo ""

    for p in "${PORT_ORDER[@]}"; do
        local type_lower=$(echo "${PORT_TYPE[$p]}" | tr '[:upper:]' '[:lower:]')
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

    echo "    dut: $TOP_ENTITY port map ("
    local first=true
    for p in "${PORT_ORDER[@]}"; do
        local sep=","; [ "$first" = true ] && { sep=""; first=false; }
        echo "        $sep ${PORT_ORIG[$p]} => tb_${p}"
    done
    echo "    );"
    echo ""

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

    echo "    stim_proc: process"
    echo "    begin"

    if [ "$EVAL_MODE" = "SEQUENTIAL" ]; then
        if [ -n "$rst_lower" ]; then
            echo "        -- Aplicar reset ($RESET_TYPE, activo=$RESET_ACTIVE)"
            echo "        tb_${rst_lower} <= $RESET_ACTIVE_VAL;"
            if [ "$RESET_TYPE" = "sync" ]; then
                echo "        for i in 1 to $RESET_CYCLES loop"
                echo "            wait until rising_edge(tb_${clk_lower});"
                echo "        end loop;"
                echo "        wait for 1 ns;"
                echo "        tb_${rst_lower} <= $RESET_INACTIVE_VAL;"
            else
                echo "        wait for $((RESET_CYCLES))*$CLK_PERIOD;"
                echo "        tb_${rst_lower} <= $RESET_INACTIVE_VAL;"
            fi
            echo ""
        fi
    fi

    local i
    for ((i=0; i<TOTAL_CASES; i++)); do
        local cname="${CASE_NAMES[$i]}"
        local cstop="${CASE_STOP_TIMES[$i]}"

        echo "        -- ============================================"
        echo "        -- CASO: $cname"
        echo "        -- ============================================"
        echo "        report \"BEGIN:${cname}\" severity note;"

        if [ "$EVAL_MODE" = "SEQUENTIAL" ]; then
            local max_cycles=1
            IFS='|' read -ra inputs <<< "${CASE_INPUTS[$i]}"
            for pair in "${inputs[@]}"; do
                [ -z "$pair" ] && continue
                local val="${pair#*=}"
                if [[ "$val" =~ ^\[.*\]$ ]]; then
                    local len=$(array_length "$val")
                    [ $len -gt $max_cycles ] && max_cycles=$len
                fi
            done
            IFS='|' read -ra outputs <<< "${CASE_OUTPUTS[$i]}"
            for pair in "${outputs[@]}"; do
                [ -z "$pair" ] && continue
                local val="${pair#*=}"
                if [[ "$val" =~ ^\[.*\]$ ]]; then
                    local len=$(array_length "$val")
                    [ $len -gt $max_cycles ] && max_cycles=$len
                fi
            done

            local c
            for ((c=1; c<=max_cycles; c++)); do
                echo "        -- ciclo $c"
                for pair in "${inputs[@]}"; do
                    [ -z "$pair" ] && continue
                    local sig="${pair%%=*}"
                    local val="${pair#*=}"
                    local sig_lower=$(echo "$sig" | tr '[:upper:]' '[:lower:]')
                    [ "$sig_lower" = "$clk_lower" ] && continue
                    local is_vec=false; is_vector_port "$sig_lower" && is_vec=true
                    if [[ "$val" =~ ^\[.*\]$ ]]; then
                        local elem=$(array_at "$val" $c)
                        [ -z "$elem" ] && continue
                        [ "$elem" = "_" ] && continue
                        local fmt=$(format_vhdl_value "$elem" "$is_vec")
                        echo "        tb_${sig_lower} <= ${fmt};"
                    else
                        if [ "$c" = "1" ]; then
                            local fmt=$(format_vhdl_value "$val" "$is_vec")
                            echo "        tb_${sig_lower} <= ${fmt};"
                        fi
                    fi
                done

                echo "        wait until rising_edge(tb_${clk_lower});"
                echo "        wait for 1 ns;"

                for pair in "${outputs[@]}"; do
                    [ -z "$pair" ] && continue
                    local sig="${pair%%=*}"
                    local val="${pair#*=}"
                    local sig_lower=$(echo "$sig" | tr '[:upper:]' '[:lower:]')
                    local is_vec=false; is_vector_port "$sig_lower" && is_vec=true
                    if [[ "$val" =~ ^\[.*\]$ ]]; then
                        local elem=$(array_at "$val" $c)
                        [ -z "$elem" ] && continue
                        [ "$elem" = "_" ] && continue
                        local fmt=$(format_vhdl_value "$elem" "$is_vec")
                        echo "        assert tb_${sig_lower} = ${fmt}"
                        echo "            report \"FAIL:${cname}:${sig}:cycle_${c}\" severity error;"
                    else
                        if [ "$c" = "$max_cycles" ]; then
                            local fmt=$(format_vhdl_value "$val" "$is_vec")
                            echo "        assert tb_${sig_lower} = ${fmt}"
                            echo "            report \"FAIL:${cname}:${sig}\" severity error;"
                        fi
                    fi
                done
            done
        else
            IFS='|' read -ra inputs <<< "${CASE_INPUTS[$i]}"
            for pair in "${inputs[@]}"; do
                [ -z "$pair" ] && continue
                local sig="${pair%%=*}"
                local val="${pair#*=}"
                local sig_lower=$(echo "$sig" | tr '[:upper:]' '[:lower:]')
                local is_vec=false; is_vector_port "$sig_lower" && is_vec=true
                local fmt=$(format_vhdl_value "$val" "$is_vec")
                echo "        tb_${sig_lower} <= ${fmt};"
            done
            echo "        wait for $cstop;"
            IFS='|' read -ra outputs <<< "${CASE_OUTPUTS[$i]}"
            for pair in "${outputs[@]}"; do
                [ -z "$pair" ] && continue
                local sig="${pair%%=*}"
                local val="${pair#*=}"
                local sig_lower=$(echo "$sig" | tr '[:upper:]' '[:lower:]')
                local is_vec=false; is_vector_port "$sig_lower" && is_vec=true
                local fmt=$(format_vhdl_value "$val" "$is_vec")
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
    } > "$out_file"
}

# ============================================================================
# GENERACIÓN DE vpl_execution
# ============================================================================

# Escribe el script vpl_execution final con resultados de evaluación
# $1=grade_fmt, $2=EVAL_MODE, $3=TOTAL_CASES, $4=passed, $5=failed, $6=comments
write_vpl_execution() {
    local grade_fmt="$1"
    local eval_mode="$2"
    local total="$3"
    local passed="$4"
    local failed="$5"
    local comments="$6"
    {
        echo "#!/bin/bash"
        echo "echo"
        echo "echo '<|--'"
        echo "echo '-Evaluación VHDL ($eval_mode)'"
        echo "echo '>+----------------------------------+'"
        echo "echo '>| Modo            : $eval_mode'"
        echo "echo '>| Casos totales   : $total'"
        echo "echo '>| Casos correctos : $passed'"
        echo "echo '>| Casos fallidos  : $failed'"
        echo "echo '>+----------------------------------+'"
        echo "echo '--|>'"
        [ -n "$comments" ] && echo "printf '$comments'"
        echo "echo"
        echo "echo 'Grade :=>>$grade_fmt'"
    } > vpl_execution
    chmod +x vpl_execution
}
