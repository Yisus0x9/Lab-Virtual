# VPL - Virtual Programming Lab for Moodle

![VPL Logo](https://vpl.dis.ulpgc.es/images/logo2.png)

VPL is the easy way to manage programming assignments in Moodle.

Its features of editing, running and evaluation of programs makes learning process
for students, and the evaluation task for teachers, easier than ever.

It's free and its code is available at GitHub. To see VPL in action visite our demo site.
This software is distributed under the terms of the GNU General
Public License version 3 (see http://www.gnu.org/licenses/gpl.txt for details)

This software is provided "AS IS" without a warranty of any kind.

For more details about VPL, visit the [VPL home page](http://vpl.dis.ulpgc.es) or
the [VPL plugin page at Moodle](http://www.moodle.org/plugins/mod_vpl).

## VHDL fork

This is a fork of VPL focused on providing robust support for **VHDL** (digital hardware
design) on top of the standard VPL workflow. It keeps full compatibility with the original
plugin while adding VHDL-specific tooling and new IDE actions.

### VHDL support for the core actions

The standard VPL actions were extended to work end to end with VHDL using **GHDL** as the
toolchain:

- **Run** — analyzes, elaborates and runs the submitted VHDL design.
- **Debug** — runs the simulation through VPL's **graphical terminal**, so the student can
  interact with the execution instead of only reading static output.
- **Automatic evaluation** — VHDL submissions are graded automatically by VPL, returning a
  proposed grade and feedback from the simulation/test results.

### New actions / buttons

Several new actions were added to the IDE toolbar to support a complete VHDL workflow,
including work with real FPGA hardware:

- **Generate Testbench** — generates a basic testbench skeleton from the student's VHDL
  source (parses the entity and its ports) and adds it as a new editable file in the IDE.
- **Remote Lab** — opens an SSH connection to a **remote FPGA lab**, transferring the
  student's design files and giving an interactive session against the real board.
- **Download from Remote** — copies one or more files generated during the remote lab
  session back into the student's files over SSH. It accepts a single file, several files
  separated by commas (e.g. `caja.bit,caja.xdc`) or a base path plus files
  (e.g. `ruta:caja.bit,caja.xdc`), with input validation.

> Note: the Remote Lab and Download actions require `sshpass` on the jail/execution server
> and network reachability to the remote FPGA board.