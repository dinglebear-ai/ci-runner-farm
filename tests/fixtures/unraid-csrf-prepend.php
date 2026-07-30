<?php
// Characterize Unraid webGUI's global POST gate: it validates the submitted
// token before the plugin endpoint runs, leaves the validated value in the
// prepend scope, and removes the token from $_POST.
$_SERVER['REQUEST_METHOD'] = 'POST';
$_SERVER['SCRIPT_NAME'] = '/plugins/ci-runner-farm/include/exec.php';
$_POST = ['csrf_token'=>'fixture-csrf', 'action'=>'csrf-prepend-probe'];
$var = ['csrf_token'=>'fixture-csrf'];
$csrf_token = $_POST['csrf_token'] ?? null;
if (!is_string($csrf_token) || !hash_equals($var['csrf_token'], $csrf_token)) {
  exit(97);
}
unset($_POST['csrf_token']);
