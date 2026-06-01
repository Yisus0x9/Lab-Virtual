<?php
// This file is part of VPL for Moodle - http://vpl.dis.ulpgc.es/
//
// VPL for Moodle is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// VPL for Moodle is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with VPL for Moodle.  If not, see <http://www.gnu.org/licenses/>.

/**
 * Class to manage edition/execution operations
 *
 * @package mod_vpl
 * @copyright 2014 Juan Carlos Rodríguez-del-Pino
 * @license http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 * @author Juan Carlos Rodríguez-del-Pino <jcrodriguez@dis.ulpgc.es>
 */

defined('MOODLE_INTERNAL') || die();
require_once(dirname(__FILE__) . '/../locallib.php');
require_once(dirname(__FILE__) . '/../vpl.class.php');
require_once(dirname(__FILE__) . '/../vpl_submission_CE.class.php');
require_once(dirname(__FILE__) . '/../vpl_example_CE.class.php');

/**
 * Class to manage edition/execution operations
 *
 * @package mod_vpl
 * @copyright 2014 Juan Carlos Rodríguez-del-Pino
 * @license http://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 * @author Juan Carlos Rodríguez-del-Pino <jcrodriguez@dis.ulpgc.es>
 */
class mod_vpl_edit {
    /**
     * Translates files from IDE to internal format
     *
     * @param array $postfiles atributes encoding, name and contents
     * @return array contents indexed by filenames
     */
    public static function filesfromide(&$postfiles) {
        $files = [];
        foreach ($postfiles as $file) {
            if ($file->encoding == 1) {
                $files[$file->name] = base64_decode($file->contents);
            } else {
                $files[$file->name] = $file->contents;
            }
        }
        return $files;
    }

    /**
     * Translates files from internal format to IDE format
     *
     * @param string[string] $from contents indexed by filenames
     * @return array of stdClass
     */
    public static function filestoide(&$from) {
        $files = [];
        foreach ($from as $name => $data) {
            $file = new stdClass();
            $file->name = $name;
            if (vpl_is_binary($name, $data)) {
                $file->contents = base64_encode($data);
                $file->encoding = 1;
            } else {
                $file->contents = $data;
                $file->encoding = 0;
            }
            $files[] = $file;
        }
        return $files;
    }

    /**
     * Converts from file internal format to old array of array format
     * @param string[string] $arrayfiles files internal format
     * @return string[][]
     */
    public static function files2object(&$arrayfiles) {
        $files = [];
        foreach ($arrayfiles as $name => $data) {
            $file = [
                    'name' => $name,
                    'data' => $data,
            ];
            $files[] = $file;
        }
        return $files;
    }

    /**
     * Save a submission version
     *
     * @param mod_vpl $vpl VPL instance
     * @param int $userid
     * @param array $files internal format
     * @param string $comments
     * @param int $version -1 for new version, or the version to replace
     * @throws Exception
     * @return int saved record id
     */
    public static function save(mod_vpl $vpl, int $userid, array &$files, string $comments = '', int $version = -1) {
        global $USER;
        $response = new stdClass();
        $response->requestsconfirmation = false;
        $response->saved = false;
        if ($version != -1) {
            $lastsub = $vpl->last_user_submission($userid);
            if ($lastsub && $lastsub->id != $version) {
                $response->requestsconfirmation = true;
                $response->question = get_string('replacenewer', VPL);
                $response->version = $lastsub->id;
                return $response;
            }
            if ($userid != $USER->id) {
                $response->requestsconfirmation = true;
                $response->question = get_string('saveforotheruser', VPL);
                $response->version = -1;
                return $response;
            }
        }
        $errormessage = '';
        if ($subid = $vpl->add_submission($userid, $files, $comments, $errormessage)) {
            \mod_vpl\event\submission_uploaded::log([
                    'objectid' => $subid,
                    'context' => $vpl->get_context(),
                    'relateduserid' => ($USER->id != $userid ? $userid : null),
            ]);
            $response->version = $subid;
            $response->saved = true;
            return $response;
        } else {
            throw new Exception(get_string('notsaved', VPL) . ': ' . $errormessage);
        }
    }
    /**
     * Updates files in running task
     *
     * @param mod_vpl $vpl VPL instance
     * @param int $userid
     * @param int $processid
     * @param array $files internal format
     * @param array $filestodelete files to delete in the running task
     * @throws Exception
     * @return boolean True if updated
     */
    public static function update(mod_vpl $vpl, int $userid, int $processid, array &$files, $filestodelete = []) {
        return mod_vpl_submission_CE::update($vpl, $userid, $processid, $files, $filestodelete);
    }

    /**
     * Returns initial/requested files of $vpl
     * @param mod_vpl $vpl
     * @return string[string] files internal format
     */
    public static function get_requested_files($vpl) {
        $reqfgm = $vpl->get_required_fgm();
        return $reqfgm->getallfiles();
    }

    /**
     * Returns last submitted files of $vpl and userid.
     * If available $compilationexecution will return compilation and execution information.
     * @param mod_vpl $vpl
     * @param int $userid
     * @param Object $compilationexecution
     * @return string[string]
     */
    public static function get_submitted_files($vpl, $userid, &$compilationexecution) {
        $compilationexecution = false;
        $lastsub = $vpl->last_user_submission($userid);
        if ($lastsub) {
            $submission = new mod_vpl_submission($vpl, $lastsub);
            $fgp = $submission->get_submitted_fgm();
            $files = $fgp->getallfiles();
            $compilationexecution = $submission->get_CE_for_editor();
            $compilationexecution->comments = $submission->get_instance()->comments;
        } else {
            $files = self::get_requested_files($vpl);
            $compilationexecution = new stdClass();
            $compilationexecution->comments = '';
            $compilationexecution->nevaluations = 0;
            $compilationexecution->freeevaluations = $vpl->get_effective_setting('freeevaluations', $userid);
            $compilationexecution->reductionbyevaluation = $vpl->get_effective_setting('reductionbyevaluation', $userid);
        }
        return $files;
    }

    /**
     * Returns the last or other submission and compilation execution information
     * @param mod_vpl $vpl
     * @param int $userid
     * @param int|boolean $submissionid
     * @return Object
     */
    public static function load($vpl, $userid, $submissionid = false) {
        global $DB;
        $response = new stdClass();
        $response->version = 0;
        $response->comments = '';
        $response->compilationexecution = false;
        $vplinstance = $vpl->get_instance();
        if ($submissionid !== false) {
            // Security checks.
            $parms = ['id' => $submissionid, 'vpl' => $vplinstance->id];
            $vpl->require_capability(VPL_GRADE_CAPABILITY);
            $res = $DB->get_records('vpl_submissions', $parms);
            if (count($res) == 1) {
                 $subreg = $res[$submissionid];
            } else {
                 $subreg = false;
            }
        } else {
            $subreg = $vpl->last_user_submission($userid);
        }
        $response->files = self::get_requested_files($vpl);
        if ($subreg) {
            $submission = new mod_vpl_submission($vpl, $subreg);
            $fgp = $submission->get_submitted_fgm();
            $response->version = $subreg->id;
            $response->comments = $subreg->comments;
            $response->files = array_merge($response->files, $fgp->getallfiles());
            $response->compilationexecution = $submission->get_CE_for_editor();
        } else {
            $compilationexecution = new stdClass();
            $compilationexecution->grade = '';
            $compilationexecution->nevaluations = 0;
            $compilationexecution->freeevaluations = $vpl->get_effective_setting('freeevaluations', $userid);
            $compilationexecution->reductionbyevaluation = $vpl->get_effective_setting('reductionbyevaluation', $userid);
            $response->compilationexecution = $compilationexecution;
        }
        return $response;
    }

    /**
     * Request the execution (run|debug|evaluate|test_evaluate) of a user's submission or test_evaluate
     * @param mod_vpl $vpl
     * @param int $userid
     * @param string $action
     * @param array $options for the execution
     * @throws Exception
     * @return Object with execution information
     */
    public static function execute($vpl, $userid, $action, $options = []) {
        global $USER;
        $example = $vpl->get_instance()->example;
        $lastsub = $vpl->last_user_submission($userid);
        if (! $lastsub && ! $example && $action != 'test_evaluate') {
            throw new Exception(get_string('nosubmission', VPL));
        }
        if ($example || ! $lastsub) {
            $submission = new mod_vpl_example_CE($vpl);
        } else {
            $submission = new mod_vpl_submission_CE($vpl, $lastsub);
        }
        $code = ['run' => 0, 'debug' => 1, 'evaluate' => 2, 'test_evaluate' => 3,
                 'remote_lab' => 4, 'remote_download' => 6];
        $traslate = ['run' => 'run', 'debug' => 'debugged',
                     'evaluate' => 'evaluated', 'test_evaluate' => 'evaluated',
                     'remote_lab' => 'run', 'remote_download' => 'run'];
        $eventclass = '\mod_vpl\event\submission_' . $traslate[$action];
        $eventclass::log($submission);
        return $submission->run($code[$action], $options);
    }

    /**
     * @Author Jesus Peñarrieta Villa
     * Generate a VHDL testbench from the files sent by the IDE.
     *
     * Parses the first VHDL source file found in $actiondata->files,
     * extracts the entity name and port block, and returns a testbench
     * skeleton as a new file named _tb.vhd.
     *
     * @param mod_vpl $vpl
     * @param int $userid
     * @param object $actiondata IDE payload with a ->files array
     * @throws Exception if no VHDL file is found or entity cannot be parsed
     * @return object with ->filename and ->content properties
     */
    public static function generate_testbench_file($vpl, $userid, $actiondata) {
        // Collect files from the IDE POST payload when the new JS is active.
        $files = [];
        if (!empty($actiondata->files)) {
            $files = self::filesfromide($actiondata->files);
        }

        // Fallback: load the last saved submission when no files were posted
        // (old cached JS sends empty data; new JS sends files via POST).
        if (empty($files)) {
            $lastsub = $vpl->last_user_submission($userid);
            if ($lastsub) {
                $files = (new \mod_vpl_submission($vpl, $lastsub))->get_submitted_files();
            }
        }

        // Find first VHDL/HDL source file among student files.
        $vhdlcontent = null;
        $vhdlfilename = null;
        $vhdlexts = ['vhd', 'vhdl', 'vh', 'v', 'sv'];
        foreach ($files as $filename => $content) {
            $ext = strtolower(pathinfo($filename, PATHINFO_EXTENSION));
            if (in_array($ext, $vhdlexts)) {
                $vhdlcontent = $content;
                $vhdlfilename = $filename;
                break;
            }
        }

        if ($vhdlcontent === null) {
            throw new \Exception(get_string('novhdlfilesfortestbench', VPL));
        }
        if (trim($vhdlcontent) === '') {
            throw new \Exception(get_string('emptyvhdlfilefortestbench', VPL, $vhdlfilename));
        }

        // Parse entity name — fallback to filename without extension.
        $entityname = strtolower(pathinfo($vhdlfilename, PATHINFO_FILENAME));
        if (preg_match('/entity\s+(\w+)\s+is/i', $vhdlcontent, $entitymatch)) {
            $entityname = strtolower($entitymatch[1]);
        }

        // Output filename: <source_basename>_tb.vhd
        $sourcebase = pathinfo($vhdlfilename, PATHINFO_FILENAME);
        $tbfilename = $sourcebase . '_tb.vhd';

        // Extract port block (handles nested parentheses).
        $ports = [];
        if (preg_match('/\bport\s*\(/is', $vhdlcontent, $pm, PREG_OFFSET_CAPTURE)) {
            $start = $pm[0][1] + strlen($pm[0][0]);
            $depth = 1;
            $end = $start;
            $len = strlen($vhdlcontent);
            while ($end < $len && $depth > 0) {
                $ch = $vhdlcontent[$end];
                if ($ch === '(') {
                    $depth++;
                } else if ($ch === ')') {
                    $depth--;
                }
                $end++;
            }
            $rawportblock = substr($vhdlcontent, $start, $end - $start - 1);
            // Remove VHDL line comments.
            $rawportblock = preg_replace('/--[^\n]*/', '', $rawportblock);
            // Parse each semicolon-separated declaration.
            foreach (explode(';', $rawportblock) as $decl) {
                $decl = trim($decl);
                if ($decl === '') {
                    continue;
                }
                // Match: name[, name]* : [in|out|inout|buffer] type [:= default]
                if (!preg_match('/^([^:]+):\s*(in|out|inout|buffer)\s+(.+?)(?::=.*)?$/is', $decl, $dm)) {
                    continue;
                }
                $dir  = strtolower(trim($dm[2]));
                $type = trim(preg_replace('/:=.*$/s', '', trim($dm[3])));
                foreach (array_filter(array_map('trim', explode(',', $dm[1]))) as $pname) {
                    $ports[] = ['name' => $pname, 'dir' => $dir, 'type' => $type];
                }
            }
        }

        // Detect clock port: name matches clk/clock/ck* and direction is in and type is std_logic.
        $clkname = null;
        foreach ($ports as $p) {
            $nl = strtolower($p['name']);
            $tl = strtolower($p['type']);
            if ($p['dir'] === 'in' && $tl === 'std_logic'
                    && ($nl === 'clk' || $nl === 'clock' || $nl === 'ck'
                        || strpos($nl, 'clk') !== false || strpos($nl, 'clock') !== false)) {
                $clkname = $p['name'];
                break;
            }
        }
        $hasclock = $clkname !== null;

        // Detect reset port.
        $rstname = null;
        foreach ($ports as $p) {
            $nl = strtolower($p['name']);
            if ($p['dir'] === 'in' && strtolower($p['type']) === 'std_logic'
                    && ($nl === 'rst' || $nl === 'reset' || $nl === 'rst_n'
                        || $nl === 'reset_n' || $nl === 'clr' || $nl === 'clear')) {
                $rstname = $p['name'];
                break;
            }
        }

        // Initial value helper.
        $initval = function(string $type): string {
            $tl = strtolower($type);
            if ($tl === 'std_logic') {
                return " := '0'";
            }
            if (preg_match('/\bvector\b|\bunsigned\b|\bsigned\b/i', $type)) {
                return ' := (others => \'0\')';
            }
            if (preg_match('/\binteger\b|\bnatural\b|\bpositive\b/i', $type)) {
                return ' := 0';
            }
            if (preg_match('/\bboolean\b/i', $type)) {
                return ' := false';
            }
            return '';
        };

        // Column width for alignment.
        $maxlen = 0;
        foreach ($ports as $p) {
            $maxlen = max($maxlen, strlen($p['name']));
        }
        $pad = function(string $s) use ($maxlen): string {
            return str_pad($s, $maxlen);
        };

        // ---- Build testbench ----
        $tb  = "library ieee;\n";
        $tb .= "use ieee.std_logic_1164.all;\n";
        $tb .= "use ieee.numeric_std.all;\n\n";
        $tb .= "entity {$entityname}_tb is\n";
        $tb .= "end entity {$entityname}_tb;\n\n";
        $tb .= "architecture sim of {$entityname}_tb is\n\n";

        // Component declaration.
        $tb .= "    component {$entityname} is\n";
        if (!empty($ports)) {
            $tb .= "        port (\n";
            $last = count($ports) - 1;
            foreach ($ports as $idx => $p) {
                $sep = ($idx < $last) ? ';' : '';
                $tb .= "            {$pad($p['name'])} : {$p['dir']} {$p['type']}{$sep}\n";
            }
            $tb .= "        );\n";
        }
        $tb .= "    end component {$entityname};\n\n";

        // Clock period constant.
        if ($hasclock) {
            $tb .= "    constant CLK_PERIOD : time := 10 ns;\n\n";
        }

        // Signal declarations.
        if (!empty($ports)) {
            $tb .= "    -- DUT signals\n";
            foreach ($ports as $p) {
                $init = ($p['dir'] !== 'out') ? $initval($p['type']) : '';
                $tb .= "    signal {$pad($p['name'])} : {$p['type']}{$init};\n";
            }
            $tb .= "\n";
        }

        $tb .= "begin\n\n";

        // DUT instantiation.
        $tb .= "    uut : component {$entityname}\n";
        if (!empty($ports)) {
            $tb .= "        port map (\n";
            $last = count($ports) - 1;
            foreach ($ports as $idx => $p) {
                $sep = ($idx < $last) ? ',' : '';
                $tb .= "            {$pad($p['name'])} => {$p['name']}{$sep}\n";
            }
            $tb .= "        );\n";
        }
        $tb .= "\n";

        // Clock generation process.
        if ($hasclock) {
            $tb .= "    clk_gen : process is\n";
            $tb .= "    begin\n";
            $tb .= "        {$clkname} <= '0';\n";
            $tb .= "        wait for CLK_PERIOD / 2;\n";
            $tb .= "        {$clkname} <= '1';\n";
            $tb .= "        wait for CLK_PERIOD / 2;\n";
            $tb .= "    end process clk_gen;\n\n";
        }

        // Stimulus process.
        $tb .= "    stim_proc : process is\n";
        $tb .= "    begin\n";
        if ($rstname !== null) {
            $tb .= "        -- Apply reset\n";
            $tb .= "        {$rstname} <= '1';\n";
            if ($hasclock) {
                $tb .= "        wait for 2 * CLK_PERIOD;\n";
            } 
            $tb .= "        {$rstname} <= '0';\n";
            if ($hasclock) {
                $tb .= "        wait for CLK_PERIOD;\n\n";
            } else {
                $tb .= "        wait for 10 ns;\n\n";
            }
        } else
        $tb .= "        -- TODO: add test vectors here\n\n";
        $tb .= "        wait;\n";
        $tb .= "    end process stim_proc;\n\n";

        $tb .= "end architecture sim;\n";

        $response = new \stdClass();
        $response->filename = $tbfilename;
        $response->content  = $tb;
        return $response;
    }

    /**
     * Request the retrieve of the evaluation result
     * @param mod_vpl $vpl
     * @param int $userid
     * @param int $processid
     * @throws Exception
     * @return stdClass
     */
    public static function retrieve_result(mod_vpl $vpl, int $userid, $processid = -1) {
        if ($processid == -1) { // To keep previous behaviour.
            $processinfo = vpl_running_processes::get_run($userid, $vpl->get_instance()->id);
            if ($processinfo == false) { // No process to cancel.
                throw new Exception(get_string('serverexecutionerror', VPL) . ' No process to cancel');
            } else {
                $processid = $processinfo->id;
            }
        }
        $lastsub = $vpl->last_user_submission($userid);
        if (! $lastsub) {
            $submission = new mod_vpl_example_CE($vpl);
        } else {
            $submission = new mod_vpl_submission_CE($vpl, $lastsub);
        }
        return $submission->retrieveresult($processid);
    }

    /**
     * Request the cancel of a evaluation/execution in progress.
     * @param mod_vpl $vpl
     * @param int $userid
     * @param int $processid
     * @return string The message of not canceled or empty string
     */
    public static function cancel($vpl, $userid, int $processid) {
        $example = $vpl->get_instance()->example;
        $lastsub = $vpl->last_user_submission($userid);
        try {
            if ($example || ! $lastsub) {
                $submission = new mod_vpl_example_CE($vpl);
            } else {
                $submission = new mod_vpl_submission_CE($vpl, $lastsub);
            }
            $submission->cancelProcess($processid);
        } catch (\Throwable $e) {
            return $e->getMessage();
        }
        return '';
    }

    /**
     * Request to stop the direct run for this user and vpl activity if any
     * @param int $vplid
     * @param int $userid
     */
    public static function stopdirectrun($vplid, $userid) {
        $processes = vpl_running_processes::get_directrun($userid, $vplid);
        foreach ($processes as $process) {
            try {
                $data = new \stdClass();
                $data->adminticket = $process->adminticket;
                $request = vpl_jailserver_manager::get_action_request('stop', $data);
                vpl_jailserver_manager::get_response($data->server, $request, $error);
            } catch (\Throwable $e) {
                debugging("Process directrun in execution server not sttoped or not found", DEBUG_DEVELOPER);
            }
            vpl_running_processes::delete($userid, $vplid, $process->adminticket);
        }
    }

    /**
     * Request the direct run code in an execution server
     *
     * @param mod_vpl $vpl
     * @param int $userid
     * @param string $command
     * @param array $files
     * @return stdClass with the response information
     * @throws Exception
     */
    public static function directrun($vpl, $userid, $command, $files) {
        $vplid = $vpl->get_instance()->id;
        self::stopdirectrun($vplid, $userid);
        $executefilename = '.vpl_directrun.sh';
        $maxmemory = 2000 * 1000 * 1000;
        $localservers = $vpl->get_instance()->jailservers;
        $error = '';
        $server = vpl_jailserver_manager::get_server($maxmemory, $localservers, $error);
        if ($server == '') {
            $manager = $vpl->has_capability(VPL_MANAGE_CAPABILITY);
            $men = get_string('nojailavailable', VPL);
            if ($manager) {
                $men .= ": " . $error;
            }
            throw new Exception($men);
        }
        $data = new stdClass();
        mod_vpl_submission_CE::adaptbinaryfiles($data, $files);
        $data->files[$executefilename] = <<<DIRECTRUNCODE
#!/bin/bash
cat > vpl_execution <<CONTENTS
#!/bin/bash
$command
CONTENTS
chmod +x vpl_execution
DIRECTRUNCODE;
        $data->filestodelete[$executefilename] = 1;
        $data->fileencoding[$executefilename] = 0;
        $data->execute = $executefilename;
        $plugin = new stdClass();
        require(dirname(__FILE__) . '/../version.php');
        $pluginversion = $plugin->version;
        $data->pluginversion = $pluginversion;
        $data->interactive = 1;
        $data->lang = vpl_get_lang();
        $data->maxtime = 1000000;
        $data->maxfilesize = $maxmemory;
        $data->maxmemory = $maxmemory;
        $data->maxprocesses = 10000;
        $request = vpl_jailserver_manager::get_action_request('directrun', $data);
        $error = '';
        $jailresponse = vpl_jailserver_manager::get_response($server, $request, $error);
        if ($jailresponse === false) {
            $manager = $vpl->has_capability(VPL_MANAGE_CAPABILITY);
            if ($manager) {
                throw new Exception(get_string('serverexecutionerror', VPL) . "\n" . $error . ' ' . $server . ' ' . $request);
            }
            throw new Exception(get_string('serverexecutionerror', VPL));
        }
        $parsed = parse_url($server);
        $response = new stdClass();
        $response->server = $parsed['host'];
        $response->executionPath = $jailresponse['executionticket'] . '/execute';
        $usinghttp = $parsed['scheme'] == 'http';
        $usinghttps = $parsed['scheme'] == 'https';
        $response->port = $usinghttp ? $parsed['port'] : $jailresponse['port'];
        $response->securePort = $usinghttps ? $parsed['port'] : $jailresponse['secureport'];
        $response->wsProtocol = get_config('mod_vpl')->websocket_protocol;
        $response->homepath = $jailresponse['homepath'];
        $process = new stdClass();
        $process->userid = $userid;
        $process->vpl = $vplid;
        $process->adminticket = $jailresponse['adminticket'];
        $process->server = $server;
        $process->type = 4;
        $response->processid = vpl_running_processes::set($process);
        return $response;
    }
}
