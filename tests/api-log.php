<?php
declare(strict_types=1);

$root = dirname(__DIR__);
$cli = $root . '/src/usr/local/emhttp/plugins/ci-runner-farm/include/api-log.php';
$tmp = sys_get_temp_dir() . '/crf-api-log-' . bin2hex(random_bytes(6));
mkdir($tmp, 0700, true);

function rr(string $p): void {
    if (is_link($p) || is_file($p)) { @unlink($p); return; }
    if (!is_dir($p)) return;
    foreach (array_diff(scandir($p) ?: [], ['.', '..']) as $n) rr($p . '/' . $n);
    @rmdir($p);
}
register_shutdown_function(static fn() => rr($GLOBALS['tmp']));
function ok(bool $v, string $m): void { if (!$v) throw new RuntimeException($m); }
function fx(string $n, string $s, int $m=0600): string {
    $p=$GLOBALS['tmp'].'/'.$n; file_put_contents($p,$s); chmod($p,$m); return $p;
}
function run(string $mode,string $file,string $lines,string $source): array {
    $pipes=[]; $p=proc_open([PHP_BINARY,$GLOBALS['cli'],$mode,$file,$lines,$source],
      [0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);
    ok(is_resource($p),'launch'); fclose($pipes[0]);
    $out=stream_get_contents($pipes[1]); $err=stream_get_contents($pipes[2]);
    fclose($pipes[1]); fclose($pipes[2]);
    return [proc_close($p),$out,$err];
}
function bad(string $label,string $mode,string $file,string $lines,string $source,int $want=5): void {
    [$rc,$out]=run($mode,$file,$lines,$source);
    ok($rc===$want,"$label rc=$rc"); ok($out==='',"${label} stdout");
}

$token='abcdefghijklmnopqrstuvwxyz';
$plain=implode(chr(10),[
 'old line',
 chr(27).'[31mcolored'.chr(27).'[0m',
 'github_pat_'.$token,
 'Authorization: Bearer '.$token,
 'password='.$token,
 '-----BEGIN PRIVATE KEY-----',
 'pemmaterial',
 '-----END PRIVATE KEY-----',
 'latest',
]).chr(10);
$file=fx('plain.log',$plain);
[$rc,$out,$err]=run('plain',$file,'7','runner:ci-runner-rust-1');
ok($rc===0 && $err==='','plain');
$j=json_decode($out,true,16,JSON_THROW_ON_ERROR);
ok($j['truncated']===false && str_ends_with($j['content'],'latest'),'full redacted log');
ok(str_contains($j['content'],'colored') && !str_contains($j['content'],chr(27)),'ansi');
ok(!str_contains($j['content'],$token) && !str_contains($j['content'],'pemmaterial'),'secret');
ok(str_contains($j['content'],'[REDACTED]') && str_contains($j['content'],'[REDACTED PEM]'),'redact');

[$rc,$out]=run('plain',fx('tail.log',"one\ntwo\nthree\n"),'2','controller');
$j=json_decode($out,true,16,JSON_THROW_ON_ERROR);
ok($rc===0 && $j['content']==="two\nthree" && $j['truncated']===true,'plain tail');

$json=json_encode(['ok'=>true,'log'=>"one\ntwo\nthree\n"],JSON_THROW_ON_ERROR);
[$rc,$out]=run('json',fx('json.log',$json),'2','history:ci-runner-jit-rust-aaaaaaaaaaaaaaaaaaaa');
$j=json_decode($out,true,16,JSON_THROW_ON_ERROR);
ok($rc===0 && $j['content']==="two\nthree" && $j['truncated']===true,'json');

$giant=str_repeat('🙂',18000);
[$rc,$out]=run('plain',fx('giant.log',$giant),'1','controller');
$j=json_decode($out,true,16,JSON_THROW_ON_ERROR);
ok($rc===0 && $j['truncated']===true && strlen($j['content'])<=65536 && preg_match('//u',$j['content'])===1,'utf8');

$control='good'.chr(1).'bad'.chr(127).'end'.chr(10);
[$rc,$out]=run('plain',fx('control.log',$control),'1','controller');
$j=json_decode($out,true,16,JSON_THROW_ON_ERROR);
ok($rc===0 && $j['content']==='goodbadend','controls');

bad('zero','plain',$file,'0','controller');
bad('over','plain',$file,'501','controller');
bad('source','plain',$file,'1',"bad\nsource");
bad('mode','plain',fx('mode.log','x',0644),'1','controller');
$target=fx('target.log','x'); $link=$tmp.'/link.log'; symlink($target,$link);
bad('link','plain',$link,'1','controller');
bad('nul','plain',fx('nul.log','a'.chr(0).'b'),'1','controller');
bad('utf8','plain',fx('utf8.log',chr(255)),'1','controller');
bad('json','json',fx('bad.json','{'),'1','controller');
bad('shape','json',fx('shape.json',json_encode(['ok'=>false,'log'=>'x'],JSON_THROW_ON_ERROR)),'1','controller');
bad('oversize','plain',fx('oversize.log',str_repeat('x',1048577)),'1','controller',7);

printf("api-log: OK\n");
