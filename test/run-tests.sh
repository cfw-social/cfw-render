#!/usr/bin/env bash
# test/run-tests.sh — behavioral suite against test/mock-server.py. No live
# services (implementation-plan.md §10). Boots a fresh mock server per case,
# runs bin/cfw-render.sh against it with CFW_RENDER_DIRECTOR_CMD pointed at
# test/fake-director.sh, and asserts on calls.jsonl / journal.tsv / scratch
# state. Exit 0 iff every case passes.
set -u

# The runner sandbox allows writes only under its TMPDIR and refuses /tmp.
# Remember the directory now: a later step must not make tempfile fall back.
SUITE_TMPDIR="${TMPDIR-}"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

FAILURES=0
PASS_COUNT=0

pass() { printf '  PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { printf '  FAIL  %s — %s\n' "$1" "$2"; FAILURES=$((FAILURES+1)); }

# Only recorded children of this runner may be cleaned up. No command matching.
stop_test_tree() {
  local owner
  owner="$(exec python3 -c 'import os; print(os.getppid())')" || return 1
  python3 "$TEST_DIR/stop-owned-tree.py" "$1" "$owner" || return 1
  # SIGKILL is the expected fixture shutdown, not a failed assertion.
  if wait "$1" 2>/dev/null; then :; fi
}
process_cleanup_case() {
  python3 - "$TEST_DIR" <<'PY'
import importlib.util, os, pathlib, subprocess, sys, tempfile, time
spec = importlib.util.spec_from_file_location('cleanup', pathlib.Path(sys.argv[1])/'stop-owned-tree.py')
cleanup = importlib.util.module_from_spec(spec); spec.loader.exec_module(cleanup)
with tempfile.TemporaryDirectory() as tmp:
    marker = pathlib.Path(tmp)/'child'
    unrelated = subprocess.Popen(['sleep', '30'])
    root = subprocess.Popen(['bash', '-c', 'sleep 30 & echo $! > "$1"; wait', '_', str(marker)])
    try:
        for _ in range(100):
            if marker.exists() and marker.read_text().strip(): break
            time.sleep(.01)
        child = int(marker.read_text())
        try:
            cleanup.stop_owned_tree(unrelated.pid, os.getpid()+1)
            raise AssertionError('accepted a non-owned process')
        except ValueError:
            pass
        cleanup.stop_owned_tree(root.pid, os.getpid())
        root.wait(timeout=5)
        for _ in range(100):
            if child not in cleanup.processes(): break
            time.sleep(.01)
        assert child not in cleanup.processes(), 'descendant survived cleanup'
        assert unrelated.poll() is None, 'unrelated sleep 30 was stopped'
    finally:
        if root.poll() is None: cleanup.stop_owned_tree(root.pid, os.getpid())
        root.wait(timeout=5)
        unrelated.terminate(); unrelated.wait(timeout=5)
print('PASS: exact owned tree stopped; unrelated matching command survives; foreign owner rejected')
PY
}
if [[ "${1:-}" == --process-cleanup ]]; then
  process_cleanup_case
  exit $?
fi
if [[ -z "${1:-}" ]]; then
  if process_cleanup_case; then pass "test-owned process cleanup"; else fail "test cleanup" "unsafe cleanup"; exit 1; fi
fi

# Deterministic scheduling regression: run the real loop/backoff implementation
# with only time, server replies and machine state replaced by local fixtures.
short_tick_wake_case() {
  python3 - "$REPO_DIR" <<'PY'
import os, pathlib, subprocess, sys, tempfile
source=(pathlib.Path(sys.argv[1])/'bin/cfw-render.sh').read_text()
loop=source[source.index('loop_sleep() {'):]
with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp)
    script=r'''
set -u
CR_CAPACITY_IDLE_CLAIM_SECS=0.3
CR_CLAIM_BACKOFF_BASE_SECS=0.3
CR_CLAIM_BACKOFF_MAX_SECS=3
CR_WAKE_GAP_SECS=30
LAST_PAUSE_STATE=none
STARTED=0
CFW_RENDER_STATE_DIR="$ROOT"
cr_tick_lock_touch() { :; }
prune_running() { RUNNING=0; }
cr_pause_state() { echo none; }
cr_log() { printf '%s\n' "$*" >> "$ROOT/log"; }
cr_now_epoch() { if [[ -f "$ROOT/jumped" ]]; then echo 131; else echo 100; fi; }
sleep() {
  if [[ "$backoff" == 3 && ! -f "$ROOT/jumped" ]]; then
    [[ "$1" == 0.300 ]] || exit 8
    : > "$ROOT/jumped"
  fi
}
gated_claim_round() {
  if [[ -f "$ROOT/jumped" ]]; then
    [[ "$backoff" == 0 && "$CR_WOKE" == 1 ]] || exit 9
    echo claim >> "$ROOT/claims"
    exit 0
  fi
  return 2
}
'''
    p=subprocess.run(['bash','-c',script+loop],env={**os.environ,'ROOT':str(root)},capture_output=True,text=True,timeout=10)
    assert p.returncode==0,(p.returncode,p.stdout,p.stderr)
    log=(root/'log').read_text()
    assert 'retrying every 3s' in log and 'woke from sleep (31s gap)' in log
    assert log.count('claim back-off: reset after sleep')==1
    assert (root/'claims').read_text()=='claim\n'
    print('PASS: real loop reaches 3s cap; tick 0.3 + 31s jump resets backoff before next claim')
PY
}
if [[ "${1:-}" == --wake-short-tick ]]; then short_tick_wake_case; exit $?; fi

# Hermetic groups that run scripts under a bash of their own choosing use the
# bash running this suite ($BASH, a full path). /bin/bash 3.2 keeps here-doc
# and here-string temp files in the system temp dir whatever TMPDIR says; the
# runner sandbox refuses that dir, while this suite's own here-docs work.
TEST_SUITE_BASH="$BASH"
export TEST_SUITE_BASH

if [[ "${1:-}" == --app-key-retry ]]; then
  python3 "$TEST_DIR/app-key-retry.py"
  exit $?
fi
if [[ -z "${1:-}" ]]; then
  if python3 "$TEST_DIR/app-key-retry.py"; then pass "durable setup key replacement retries"; else fail "key replacement retry" "regression failed"; fi
fi

# Negotiated checkpoint fixtures only: no production manifest/version changes.
local_checkpoint_cases() {
  python3 - "$REPO_DIR" <<'PY'
import copy, importlib.util, json, os, pathlib, shutil, subprocess, sys, tempfile, time
repo = pathlib.Path(sys.argv[1])
helper = repo/'bin/cfw-render-checkpoint.py'
spec = importlib.util.spec_from_file_location('checkpoint', helper)
cp = importlib.util.module_from_spec(spec); spec.loader.exec_module(cp)
script = r'''
set -uo pipefail
source "$REPO/bin/cfw-render-lib.sh"
source "$REPO/bin/cfw-render-engine.sh"
source "$REPO/bin/cfw-render-harness.sh"
cr_engine_detect() { echo codex; }
cr_engine_limit_detect() { return 1; }
cr_engine_limit_until() { echo ''; }
cr_harness_heartbeat_start() { :; }
cr_harness_heartbeat_stop() { :; }
cr_h_run_with_timeout() { shift; "$@"; }
cr_report_step() {
  python3 -c 'import json,sys; print(json.dumps({"attempt":sys.argv[1],"seq":sys.argv[2],"event":sys.argv[3],"extra":json.loads(sys.argv[4])}))' "$3" "$4" "$5" "$6" >> "$ROOT/reports"
  if [[ "${LOSE_ACK:-}" == "$5" && ! -e "$ROOT/.lost-ack" ]]; then touch "$ROOT/.lost-ack"; return 75; fi
  if [[ "${REVOKE:-0}" == 1 && "$5" == step_started ]]; then printf '{"ok":true,"directive":"stop_after_step"}'; return; fi
  printf '{"ok":true,"directive":"continue"}'
}
cr_h_upload_with_retry() { echo unexpected-upload >> "$ROOT/network"; return 1; }
cr_h_restore_saved_outputs() { echo unexpected-download >> "$ROOT/network"; return 1; }
cr_harness_run "$JOB/order.json" "$JOB" "$RECIPE"
'''
with tempfile.TemporaryDirectory(prefix='cfw-local-checkpoints-') as tmp:
    root = pathlib.Path(tmp).resolve()
    recipe = root/'recipe'; (recipe/'steps').mkdir(parents=True); (recipe/'checks').mkdir()
    for sid in ('a','b','c'): (recipe/'steps'/f'{sid}.md').write_text('Synthetic offline test.')
    (recipe/'checks/valid.sh').write_text('[[ -s "$1/saves/image.png" ]]\n')
    image = root/'fixture.png'
    subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','color=white:s=16x16','-frames:v','1',str(image)],check=True)
    engine = root/'engine'
    engine.write_text('''#!/usr/bin/env bash
set -eu
printf '%s\\n' "$CFW_STEP_ID" >> "$ROOT/engines"
for save in $CFW_STEP_SAVES; do
  name="${save/:/.}"
  case "$name" in
    *.png) cp "$ROOT/fixture.png" "saves/$name" ;;
    *) printf '{"instagram":{"caption":"Synthetic caption","hashtags":["#test"]}}' > "saves/$name" ;;
  esac
done
if [[ "${FAIL_STEP:-}" == "$CFW_STEP_ID" ]]; then printf invalid > saves/image.png; fi
'''); engine.chmod(0o700)
    manifest = {'recipe':'fixture','recipeVersion':'1.0.0','steps':[
        {'id':'a','runsOn':'computer','instructions':'steps/a.md','saves':[{'id':'x','kind':'json'}]},
        {'id':'b','runsOn':'computer','instructions':'steps/b.md','when':{'inputPresent':'unused'},'saves':[]},
        {'id':'c','runsOn':'computer','instructions':'steps/c.md','saves':[{'id':'image','kind':'image'},{'id':'copy','kind':'json'}],
         'checks':[{'id':'valid'}]}],
        'finalOutputs':[{'stepId':'c','saveId':'image','role':'deliverable'},{'stepId':'c','saveId':'copy','role':'captions'}]}
    env = {'PATH':os.environ['PATH'],'TMPDIR':os.environ.get('TMPDIR','/tmp'),'HOME':str(root),'REPO':str(repo),'ROOT':str(root),'RECIPE':str(recipe),
           'CFW_WORKER_ID':'install-A','CFW_RENDER_LOCAL_CHECKPOINTS':'1','CFW_RENDER_ENGINE_CMD':str(engine),
           'CFW_RENDER_STATE_DIR':str(root/'state'),'CFW_RENDER_LOG_DIR':str(root/'logs')}
    def claim(name, attempt='att1', action='start', generation=0, resume='a'):
        d = root/name; d.mkdir(exist_ok=True)
        o = {'id':name,'brandId':'brand1','recipeVersion':'1.0.0','manifest':copy.deepcopy(manifest),
             'attempt':{'id':attempt},'checkpoint':{'mode':'local-v1','action':action,'generation':generation},
             'resumeFromStepId':resume,'taskOrder':{}}
        (d/'order.json').write_text(json.dumps(o)); return d, o
    def put(d, o): (d/'order.json').write_text(json.dumps(o))
    def run(d, expected=0, **extra):
        p = subprocess.run(['bash','-c',script],env={**env,'JOB':str(d),**extra},capture_output=True,text=True,timeout=60)
        assert p.returncode == expected, (p.returncode,expected,p.stdout,p.stderr[-4000:])
        return json.loads(p.stdout) if expected == 0 else None
    def command(d, cmd, *args, worker='install-A', expected=0):
        p = subprocess.run([sys.executable,str(helper),cmd,str(d),worker,*args],capture_output=True,text=True)
        assert p.returncode == expected, (cmd,p.stderr)
        return json.loads(p.stdout) if not expected else None
    d,o = claim('job')
    run(d,30,FAIL_STEP='c')
    assert (root/'engines').read_text().splitlines() == ['a','c']
    d,o = claim('job','att2','resume',resume='c'); outputs=run(d)
    assert (root/'engines').read_text().splitlines() == ['a','c','c']
    assert [x['id'] for x in outputs] == ['image','copy']
    d,o = claim('job','att3','finalize-only',resume=''); assert run(d) == outputs
    assert (root/'engines').read_text().splitlines() == ['a','c','c']
    assert not (root/'network').exists()
    state = json.loads((d/'checkpoint.json').read_text())
    assert state['identity']['workerId']=='install-A' and state['stages']['b']['event']=='step_skipped'
    reports = [json.loads(x) for x in (root/'reports').read_text().splitlines()]
    for att in ('att1','att2','att3'):
        seqs=[int(x['seq']) for x in reports if x['attempt']==att]; assert seqs==sorted(set(seqs))
    command(d,'init',worker='install-B',expected=31)
    saved=d/'steps/a/saves/x.json'; original=saved.read_bytes()
    for bad in (b'',b'changed'):
        saved.write_bytes(bad); run(d,31)
    saved.unlink(); saved.symlink_to(image); run(d,31); saved.unlink(); run(d,31); saved.write_bytes(original)
    bad_version=copy.deepcopy(o); bad_version['manifest']['recipeVersion']='2'; put(d,bad_version); run(d,31); put(d,o)
    # Every range form rejects before engine, even an apparently full range or null.
    before=(root/'engines').read_bytes()
    for field,value in [('stageRange',{'fromStepId':'a','toStepId':'c'}),('stageRange',None),
                        ('stopAfterStepId','a'),('stageRangeCompleted',True),
                        ('taskOrder',{'stageRange':{'fromStepId':'a','toStepId':'a'}})]:
        bounded=copy.deepcopy(o); bounded[field]=value; put(d,bounded); run(d,31)
        command(d,'init',expected=31)
    put(d,o); run(d,31,CFW_RENDER_LOCAL_CHECKPOINTS='0')
    unknown=copy.deepcopy(o); unknown['checkpoint']['mode']='unknown'; put(d,unknown); run(d,31); put(d,o)
    assert before==(root/'engines').read_bytes()
    for refs in ([],[{'stepId':'a','saveId':'x','role':'deliverable'}],
                 [{'stepId':'c','saveId':'missing','role':'deliverable'}]):
        f,bad=claim('mapping'+str(len(json.dumps(refs)))); bad['manifest']['finalOutputs']=refs; put(f,bad); run(f,31)
    # Lost acknowledgement is replayed at the same seq; new attempts never reuse it.
    lost,lo=claim('lost'); run(lost,31,LOSE_ACK='step_completed')
    pending=command(lost,'pending'); run(lost)
    assert pending[0]['event']=='step_completed' and command(lost,'pending')==[]
    old,oo=claim('old'); (root/'.lost-ack').unlink(); run(old,31,LOSE_ACK='step_completed')
    pending=command(old,'pending'); old,oo=claim('old','att2','resume'); run(old)
    st=json.loads((old/'checkpoint.json').read_text())
    assert st['attempts']['att1']['pending']==pending and st['stages']['a']['acknowledgedAttempts']==['att2']
    rev,ro=claim('revision','att1','resume',resume='c')
    ro['taskOrder']['resume']={'fromOrderId':'old','fromGeneration':0,'fromStepId':'c'}; put(rev,ro); run(rev)
    revoked,ro=claim('revoked'); before=(root/'engines').read_bytes(); run(revoked,22,REVOKE='1')
    assert before==(root/'engines').read_bytes()
    print('PASS: gated local resume/finalize-only, identity, corruption, range rejection, outbox replay and revocation')
    # Restore terminal acknowledgement after deliberate failed recovery probes.
    run(d)
    # Real final report with only offline upload/HTTP boundaries replaced.
    report_bin=root/'report-bin'; report_bin.mkdir()
    for name in ('cfw-render-report.sh','cfw-render-checkpoint.py'): shutil.copy2(repo/'bin'/name,report_bin/name)
    (report_bin/'cfw-render-lib.sh').write_text('''
CFW_RENDER_DIRECTOR_MODEL=sonnet
cr_log() { :; }
cr_heartbeat_stop_if_pending() { :; }
cr_mcp_call() { printf '%s\\n' "$2" >> "$ROOT/completions"; [[ "${LOSE_COMPLETE:-0}" == 1 ]] && return 75; printf '{"ok":true}'; }
''')
    uploader=report_bin/'cfw-render-upload.sh'
    uploader.write_text('#!/usr/bin/env bash\nprintf upload >> "$ROOT/uploads"\nprintf "https://media.cfw.social/image.png"\n'); uploader.chmod(0o700)
    report_env={**env,'CFW_ORDER_ID':'job','CFW_ATTEMPT_ID':'att3','CFW_API_BASE':'http://127.0.0.1:1',
                'CFW_RENDER_WORKER_KEY':'test-only','CFW_CAPTIONS_FILE':outputs[1]['path']}
    def deliver(expected, files=None, **extra):
        p=subprocess.run(['bash',str(report_bin/'cfw-render-report.sh'),'complete',*(files or [outputs[0]['path']])],
                         cwd=d,env={**report_env,**extra},capture_output=True,text=True)
        assert p.returncode==expected,(p.returncode,p.stderr)
    deliver(1,files=[str(image)])
    assert not (root/'uploads').exists()
    captions=pathlib.Path(outputs[1]['path']); original_captions=captions.read_bytes()
    captions.write_text('{}'); deliver(1); assert not (root/'uploads').exists(); captions.write_bytes(original_captions)
    deliver(1,LOSE_COMPLETE='1'); attempts=(root/'completions').read_bytes()
    deliver(1); assert (root/'completions').read_bytes()==attempts
    assert json.loads(attempts)['captions']=={'instagram':'Synthetic caption\n\n#test'}
    run(d,31)  # even finalize-only cannot repeat uncertain terminal delivery
    # Cleanup must retain the uncertainty marker as well as paid outputs.
    def life(cmd, path, *args, expected=0):
        p=subprocess.run([sys.executable,str(helper),cmd,str(path),*args],capture_output=True,text=True)
        assert p.returncode==expected,(cmd,p.stderr)
    life('active',d,str(os.getpid())); life('active',d,str(os.getpid()),expected=31)
    life('finish',d,'local-v1',str(os.getpid()+100000),expected=31)
    life('finish',d,'local-v1',str(os.getpid()))
    assert not (d/'order.json').exists() and not (d/'.active.json').exists()
    assert (d/'.delivery-started').exists() and pathlib.Path(outputs[0]['path']).exists()
    scratch=root/'scratch'; brand=scratch/'brand'; brand.mkdir(parents=True)
    for name in ('stale','active','recent','uncertain','complete','blocked'):
        p=brand/name; p.mkdir(); age=time.time()-3*86400
        (p/'.activity.json').write_text(json.dumps({'at':time.time() if name=='recent' else age}))
        if name=='active': (p/'.active.json').write_text(json.dumps({'pid':os.getpid()}))
        if name in ('uncertain','complete','blocked'): (p/'.delivery-started').mkdir()
        if name in ('complete','blocked'): (p/'.outcome').write_text('complete' if name=='complete' else 'block')
        os.utime(p,(age,age))
    life('janitor',scratch)
    assert sorted(p.name for p in brand.iterdir())==['active','recent','uncertain']
    link=brand/'link'; link.symlink_to(root/'outside'); (root/'outside').mkdir()
    life('active',link/'job',str(os.getpid()),expected=31); assert not (root/'outside/job').exists()
    print('PASS: ordered/caption delivery gate, lost completion is not retried, ownership/scrubbing and retained uncertainty')
    # Missing validators and corrupt nonempty media fail; one script invocation.
    check_work=root/'check-work'; (check_work/'saves').mkdir(parents=True)
    (check_work/'saves/x.json').write_text('{"ok":true}')
    decl={'recipe':'fixture','steps':[{'id':'a','saves':[{'id':'x','kind':'json'}],'checks':[{'id':'required'}]}]}
    order=root/'checks.json'; order.write_text(json.dumps({'manifest':decl}))
    def validate(expected):
        p=subprocess.run([sys.executable,str(repo/'bin/cfw-render-checks.py'),'run',str(order),str(recipe),str(check_work),'a'],capture_output=True,text=True)
        assert p.returncode==expected,(p.stdout,p.stderr)
        assert str(root) not in p.stdout and 'private-log' not in p.stdout
    validate(1)
    validator=recipe/'checks/required.sh'; validator.write_text('printf run >> "$1/count"\necho private-log\nexit 1\n')
    validate(1); assert (check_work/'count').read_text()=='run'
    validator.write_text('printf run >> "$1/count"\n'); validate(0)
    for kind,suffix in [('json','json'),('image','png'),('video','mp4')]:
        decl['steps'][0]['saves']=[{'id':'bad','kind':kind}]
        (check_work/f'saves/bad.{suffix}').write_text('corrupt but nonempty')
        order.write_text(json.dumps({'manifest':decl})); validate(1)
    for path in (repo/'skills').glob('p-*/manifest.json'):
        real=json.loads(path.read_text()); assert 'finalOutputs' not in real
    caps=subprocess.run(['bash','-c','source "$REPO/bin/cfw-render-engine.sh"; cr_engine_manifests_json() { echo "[]"; }; cr_engines_json() { echo "[]"; }; cr_engine_capabilities_json codex "$RECIPE"'],env=env,capture_output=True,text=True,check=True)
    assert 'checkpointProtocols' not in json.loads(caps.stdout)
    print('PASS: missing validator, corrupt saves, single invocation, unchanged recipes and no advertised checkpoint capability')
PY
}
if [[ "${1:-}" == --local-checkpoints ]]; then
  local_checkpoint_cases
  exit $?
fi
if [[ -z "${1:-}" ]]; then
  if local_checkpoint_cases; then pass "negotiated local checkpoints"; else fail "local checkpoints" "regression failed"; fi
fi

# CFW-316: disposable, offline regression coverage.
if [[ -z "${1:-}" || "${1:-}" == --timeout-recovery ]]; then
if python3 - "$REPO_DIR" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
repo = pathlib.Path(sys.argv[1])
lib = repo/'bin/cfw-render-lib.sh'
def shell(code, root, extra=None):
    # TMPDIR: bash writes here-documents to $TMPDIR (else /tmp, which the runner
    # sandbox refuses); hand the runner's choice through to these minimal envs.
    env = {'PATH': os.environ['PATH'], 'TMPDIR': os.environ.get('TMPDIR', '/tmp'), 'HOME': str(root), 'REPO': str(repo),
           'ROOT': str(root), 'CFW_API_BASE': 'http://127.0.0.1:1',
           'CFW_RENDER_WORKER_KEY': 'cfw_render_test_only', 'CFW_WORKER_ID': 'test-worker',
           'CFW_ORDER_ID': 'test-order', 'CFW_ATTEMPT_ID': 'test-attempt',
           'CFW_RENDER_DIRECTOR_MODEL': 'sonnet', 'CFW_RENDER_STATE_DIR': str(root),
           'CFW_RENDER_SCRATCH_DIR': str(root), 'CFW_RENDER_PROVIDER_BUDGET_HEYGEN': '4',
           'CFW_RENDER_PROVIDER_WAIT_CAP': '2', 'CFW_RENDER_FINISH_GRACE_SECS': '3'}
    env.update(extra or {})
    return subprocess.run(['bash','-c',code], env=env, cwd=root, text=True,
                          capture_output=True, timeout=20)
with tempfile.TemporaryDirectory(prefix='cfw-budget-recovery-') as tmp:
    root = pathlib.Path(tmp)
    def run(code, extra=None):
        p = shell('source "$REPO/bin/cfw-render-lib.sh"\n'+code, root, extra)
        assert p.returncode == 0, (p.stdout, p.stderr)
        return p.stdout.strip()
    wait = root/'wait.tsv'
    for content, expected in [('',0), ('start\theygen\t100\nend\theygen\t140\n',40),
        ('start\theygen\t900\n',100),
        ('start\theygen\t100\nstart\theygen\t110\nend\theygen\t140\n',40),
        ('start\theygen\t1\nend\theygen\t2000\n',900),
        ('start\tunknown\t100\nend\tunknown\t140\n',0),
        ('start\theygen\t100\nend\theygen\t140\nstart\theygen\t120\nend\theygen\t160\n',60),
        ('start\theygen\tnot-a-date\n',0)]:
        wait.write_text(content)
        assert run('cr_provider_wait_excluded "$ROOT/wait.tsv" 100 1000') == str(expected)
    wait.unlink()
    assert run('cr_provider_wait_excluded "$ROOT/wait.tsv" 100 1000') == '0'
    wait.symlink_to(lib)
    assert run('cr_provider_wait_excluded "$ROOT/wait.tsv" 100 1000') == '0'
    wait.unlink()
    assert run('cr_recipe_budget 3 p-reels-pip-heygen video') == '7'
    assert run('cr_recipe_budget 3 p-reels-pip-heygen image') == '3'
    assert run('cr_recipe_budget 3 unknown video') == '3'
    print('  PASS  budgets: missing/malformed/overlapping waits, lifetime clamp and image exclusion')

    # Run the actual watchdog against a virtual clock. No processes are killed.
    watch = '''
printf 100 > clock
: > kills
sleep() { local n; n=$(cat clock); printf '%s' "$((n + $1))" > clock; }
date() { cat clock; }
cr_kill_tree() { printf '%s %s %s\\n' "$1" "$2" "$(cat clock)" >> kills; }
cr_budget_watchdog 999999 3 "$ROOT/wait.tsv" "$ROOT" "${DIRECTIVE:-}"
cat kills
'''
    assert 'TERM 103' in run(watch)
    wait.write_text('start\theygen\t100\n')
    assert 'TERM 105' in run(watch)  # open wait hits the absolute outer cap
    wait.write_text('start\theygen\t100\nend\theygen\t102\n')
    assert 'TERM 105' in run(watch)
    wait.write_text('')
    (root/'final').mkdir()
    (root/'final/cover.png').write_text('not a full carousel')
    assert 'TERM 103' in run(watch)  # final files alone grant no grace
    (root/'.delivery-started').mkdir()
    assert 'TERM 106' in run(watch)
    (root/'directive').write_text('cancel')
    assert 'TERM 101' in run(watch, {'DIRECTIVE':str(root/'directive')})
    (root/'.delivery-started').rmdir()
    print('  PASS  watchdog: bounded open waits, explicit finish grace and cancellation priority')

    # Real harness timeout: only this test-owned engine group is signalled.
    (root/'order.json').write_text('{"recipe":"fixture","kind":"image"}')
    (root/'directive').write_text('continue')
    p = shell('''source "$REPO/bin/cfw-render-lib.sh"
source "$REPO/bin/cfw-render-harness.sh"
CR_H_ORDER_DIR="$ROOT"
cr_h_run_with_timeout 1 bash -c 'sleep 8'
rc=$?
[[ "$rc" == 143 || "$rc" == 137 ]] && [[ -f .retain-artifacts ]]
''', root)
    assert p.returncode == 0, p.stderr
    print('  PASS  manifest engine timeout retains artifacts and reaps its process group')

    # Real report logic with file-only mock transport/upload. No network calls.
    bins = root/'bin'; bins.mkdir()
    shutil.copy(repo/'bin/cfw-render-report.sh', bins)
    (bins/'cfw-render-lib.sh').write_text(lib.read_text()+'''\ncr_heartbeat_stop_if_pending() { :; }
cr_mcp_call() {
  printf '%s\\n' "$2" >> "$ROOT/calls"
  if [[ "${LOST_REPLY:-0}" == 1 ]]; then return 1; fi
  printf '{"ok":true}'
}
''')
    upload = bins/'cfw-render-upload.sh'
    upload.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$1" >> "$ROOT/uploads"\nprintf "https://media.cfw.social/%s" "$(basename "$1")"\n')
    upload.chmod(0o755)
    (root/'final/slide-2.png').write_text('slide two')
    (root/'final/captions.json').write_text('{"instagram":"caption"}')
    command = 'bash "$ROOT/bin/cfw-render-report.sh" complete final/slide-2.png final/cover.png final/captions.json'
    p = shell(command, root, {'LOST_REPLY':'1'})
    assert p.returncode != 0 and not (root/'.outcome').exists()
    assert (root/'.delivery-started/files.json').exists()
    p = shell(command, root)
    assert p.returncode != 0
    calls = (root/'calls').read_text().splitlines()
    assert len(calls) == 1, calls
    d = json.loads(calls[0])
    assert d['attemptId'] == 'test-attempt'
    assert [x['url'].split('/')[-1] for x in d['outputs']] == ['slide-2.png','cover.png']
    assert d['captions']['instagram'] == 'caption'
    assert len((root/'uploads').read_text().splitlines()) == 2
    assert shell('bash "$ROOT/bin/cfw-render-report.sh" block timeout', root).returncode != 0
    # Independent clean order: acknowledgement precedes optional local copy.
    clean = root/'clean'; clean.mkdir()
    p = shell('cd "$ROOT/clean"; bash "$ROOT/bin/cfw-render-report.sh" complete https://media.cfw.social/slide.png', root)
    assert p.returncode == 0, p.stderr
    assert (clean/'.outcome').read_text().strip() == 'complete'
    print('  PASS  lost completion reply: no retry/upload/block; explicit ordered outputs and attempt identity preserved')

    # The production transport must also avoid its ordinary curl retries for
    # terminal completion, even if the connection dies after server commit.
    run('''curl() { echo called >> curl-count; return 28; }
cr_mcp_call complete_render_order '{}' >/dev/null 2>&1
[[ "$(wc -l < curl-count | tr -d ' ')" == 1 ]]
''')
    # Provider event path containment and strict provider name validation.
    wait.write_text('')
    p = shell('bash "$ROOT/bin/cfw-render-report.sh" provider-wait-start heygen', root,
              {'CFW_RENDER_WAIT_FILE':str(wait)})
    assert p.returncode == 0 and 'start\theygen\t' in wait.read_text(), p.stderr
    p = shell('bash "$ROOT/bin/cfw-render-report.sh" provider-wait-start unknown', root,
              {'CFW_RENDER_WAIT_FILE':str(wait)})
    assert p.returncode == 2
    p = shell('bash "$ROOT/bin/cfw-render-report.sh" provider-wait-start heygen', root,
              {'CFW_RENDER_WAIT_FILE':str(lib)})
    assert p.returncode == 2
    source = (repo/'bin/cfw-render.sh').read_text()
    assert 'complete final/*' not in source
    identity_code = source.split('CFW_ATTEMPT_ID="$(python3 -c \'', 1)[1].split("' <<<", 1)[0]
    for order, expected in [({'attempt':{'id':'a'}}, 'a'),
        ({'attempt':{'id':'a'},'manifest':{'steps':[]}}, ''),
        ({'attempt':{'id':'a'},'manifest':{'steps':[]},'taskOrder':{'stageRange':{'fromStepId':'one'}}}, 'a')]:
        p = subprocess.run([sys.executable, '-c', identity_code], input=json.dumps(order), capture_output=True, text=True)
        assert p.returncode == 0 and p.stdout.strip() == expected, p.stderr
    # Step 7 moved retention into the shared checkpoint lifecycle helper.
    # Exercise that helper, rather than asserting the old inline implementation.
    retained = root/'retention/brand/order'; retained.mkdir(parents=True)
    (retained/'.delivery-started').mkdir()
    os.utime(retained, (1, 1))
    p = subprocess.run([sys.executable, str(repo/'bin/cfw-render-checkpoint.py'),
                        'janitor', str(root/'retention')], capture_output=True, text=True)
    assert p.returncode == 0 and (retained/'.delivery-started').is_dir(), p.stderr
    # A known upload failure occurs before any terminal RPC. It may block, but
    # its delivery lock still prevents re-upload or accidental duplicate delivery.
    rejected = root/'rejected'; rejected.mkdir()
    upload.write_text('#!/usr/bin/env bash\nexit 1\n')
    failed_command = 'cd "$ROOT/rejected"; bash "$ROOT/bin/cfw-render-report.sh" complete "$ROOT/final/slide-2.png"'
    before = (root/'calls').read_text()
    assert shell(failed_command, root).returncode != 0
    assert (rejected/'.delivery-started/upload-failed').is_file()
    assert (root/'calls').read_text() == before
    assert shell('cd "$ROOT/rejected"; bash "$ROOT/bin/cfw-render-report.sh" block "Upload failed"', root).returncode == 0
    assert (rejected/'.outcome').read_text().strip() == 'block'
    before = (root/'calls').read_text()
    assert shell(failed_command, root).returncode != 0
    assert (root/'calls').read_text() == before
    # A genuinely new admitted attempt may replace a positively acknowledged
    # block. Use the real report command, not a stub overwriting .outcome.
    def life(command, folder, *args):
        p = subprocess.run([sys.executable, str(repo/'bin/cfw-render-checkpoint.py'),
                            command, str(folder), *args], capture_output=True, text=True)
        assert p.returncode == 0, p.stderr
    life('active', rejected, str(os.getpid()))
    assert not (rejected/'.outcome').exists() and not (rejected/'.delivery-started').exists()
    upload.write_text('#!/usr/bin/env bash\necho https://media.cfw.social/retry.png\n')
    assert shell(failed_command, root).returncode == 0
    assert (rejected/'.outcome').read_text().strip() == 'complete'
    life('finish', rejected, '', str(os.getpid()))
    assert not rejected.exists(), 'acknowledged nonlocal success leaked scratch'
    assert source.index('previous delivery needs reconciliation') < source.index('printf \'%s\' "$order_json" > "$order_dir/order.json"')
    print('  PASS  completion transport is single-shot; wait writes contained; uncertain artifacts protected')
PY
then
  pass "bounded timeouts and fail-closed delivery recovery"
else
  fail "bounded timeouts and fail-closed delivery recovery" "offline regression failed"
fi
if [[ "${1:-}" == --timeout-recovery ]]; then
  (( FAILURES == 0 ))
  exit $?
fi
fi

# Exercise the real pause gate + soft-call parser without starting workers,
# hitting a network, or running the legacy suite's broad process cleanup.
# --pause-retry-only runs just this regression block.
if python3 - "$REPO_DIR" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
repo = pathlib.Path(sys.argv[1])
source = (repo/'bin/cfw-render.sh').read_text()
assert source.count('LAST_PAUSE_STATE="__unset__"') == 1
gate = source.split('LAST_PAUSE_STATE="__unset__"', 1)[1].split('\nif (( ! LOOP ));', 1)[0]
gate = 'LAST_PAUSE_STATE="__unset__"' + gate
success = json.dumps({'result': {'content': [{'text': '{"ok":true}'}]}})
def tool_error(text):
    return json.dumps({'result': {'isError': True, 'content': [{'text': text}]}})
cases = [
    ('database error', tool_error('{"ok":false,"error":"update_failed"}'), '200', 1, 3, 1),
    ('server error', json.dumps({'error': {'code': -32603, 'message': 'Temporary failure'}}), '200', 1, 3, 1),
    ('malformed reply', 'not-json', '200', 1, 3, 1),
    ('HTTP failure', '{}', '503', 3, 5, 1),
    ('old server', json.dumps({'error': {'code': -32601, 'message': 'Unknown tool: set_computer_paused'}}), '200', 1, 1, 0),
    ('SDK missing tool', tool_error('MCP error -32602: Tool set_computer_paused not found'), '200', 1, 1, 0),
    ('RPC missing tool', json.dumps({'error': {'code': -32602, 'message': 'Tool set_computer_paused not found'}}), '200', 1, 1, 0),
    ('unrelated error', json.dumps({'error': {'code': -32603, 'message': 'Unknown tool: set_computer_paused'}}), '200', 1, 3, 1),
]
harness = '''source "$REPO/bin/cfw-render-lib.sh"
curl() {
  local n
  n=$(cat "$COUNT_FILE"); n=$((n+1)); printf '%s' "$n" > "$COUNT_FILE"
  if (( n <= FAIL_CALLS )); then printf '%s\\n%s' "$FIRST_REPLY" "$HTTP_CODE"
  else printf '%s\\n200' "$SUCCESS_REPLY"; fi
}
sleep() { :; }
cr_pause_state() { printf '%s' "$PAUSE_REASON"; }
cr_on_battery() { [[ "$PAUSE_REASON" == battery ]]; }
cr_log() { :; }
cr_reach_set() { REACH="$1"; }
prune_running() { RUNNING=0; }
claim_round() { echo 'Unexpected claim' >&2; exit 99; }
cr_status_write() { printf '%s %s %s %s\\n' "$PING_SUPPORTED" "$REACH" "$CR_STATUS_LAST_ERROR" "$(cat "$COUNT_FILE")"; }
CLAIM_MAX=1
CR_STATUS_LAST_ERROR=keep-existing-error
''' + gate + '''
gated_claim_round
gated_claim_round
gated_claim_round
'''
for reason in ('owner', 'battery'):
    for name, reply, http, failures, calls, supported in cases:
        with tempfile.TemporaryDirectory(prefix='cfw-pause-retry-') as tmp:
            counter = pathlib.Path(tmp)/'calls'
            counter.write_text('0')
            env = {'PATH': os.environ['PATH'], 'TMPDIR': os.environ.get('TMPDIR', '/tmp'), 'HOME': tmp, 'REPO': str(repo),
                   'CFW_RENDER_STATE_DIR': tmp, 'CFW_API_BASE': 'http://127.0.0.1:1',
                   'CFW_RENDER_WORKER_KEY': 'test-only', 'COUNT_FILE': str(counter),
                   'FIRST_REPLY': reply, 'SUCCESS_REPLY': success, 'HTTP_CODE': http,
                   'FAIL_CALLS': str(failures), 'PAUSE_REASON': reason}
            result = subprocess.run(['bash', '-s'], input=harness, env=env,
                                    capture_output=True, text=True, timeout=20)
            assert result.returncode == 0, (name, reason, result.stderr)
            rows = result.stdout.splitlines()
            assert len(rows) == 3, (name, rows)
            assert rows[-1] == f'{supported} ok keep-existing-error {calls}', (name, reason, rows)
            assert rows[0].split()[1] == ('unreachable' if http == '503' else 'ok'), (name, rows)
            assert int(counter.read_text()) == calls
            print(f'  PASS  pause retry: {reason}, {name}')
PY
then
  pass "pause retries recover; only explicit missing-tool replies disable check-ins"
else
  fail "pause retry" "retry, old-server or reachability contract failed"
fi
if [[ "${1:-}" == --pause-retry-only ]]; then
  (( FAILURES == 0 ))
  exit $?
fi

# Legacy feedback compatibility must not grant new tool/security permissions.
if python3 - "$REPO_DIR" <<'PY'
import pathlib, sys
repo = pathlib.Path(sys.argv[1])
prompt = (repo/'lib/director-prompt.md').read_text()
assert '`feedback` (top level or\n`taskOrder.feedback`)' in prompt
assert 'Make the whole piece again from the brief' in prompt
assert 'Where creative requirements conflict with the brief, feedback wins.' in prompt
assert 'Feedback never overrides the self-contained mandate, execution restrictions,\nor security rules.' in prompt
assert '"$SELF_DIR/../lib/director-prompt.md"' in (repo/'bin/cfw-render.sh').read_text()
PY
then
  pass "legacy owner feedback applies to creative requirements, not security rules"
else
  fail "legacy owner feedback" "feedback compatibility or security precedence missing"
fi

# Reporting instructions are tested independently of the deferred checkpoint runtime.
if python3 - "$REPO_DIR" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
repo = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='cfw-reporting-prompts-') as tmp:
    work = pathlib.Path(tmp)
    manifests = sorted((repo/'skills').glob('p-*/manifest.json'))
    assert len(manifests) == 13
    for path in manifests:
        m = json.loads(path.read_text())
        assert 'RECIPE-STAGE-REPORTING.md' in (path.parent/'SKILL.md').read_text()
        for stage in m['steps']:
            if stage.get('runsOn') == 'server':
                continue
            (work/'order.json').write_text(json.dumps({'manifest':m,'taskOrder':{'intent':'synthetic'}}))
            p = subprocess.run(['bash','-c', '''source "$REPO/bin/cfw-render-harness.sh"
CR_H_RECIPE_DIR="$RECIPE"
cr_h_build_prompt "$STAGE" "$WORK" "$WORK/order.json"
'''], env={**os.environ,'REPO':str(repo),'RECIPE':str(path.parent),'STAGE':stage['id'],'WORK':str(work)},
                capture_output=True,text=True)
            assert p.returncode == 0, (m['recipe'], stage['id'], p.stderr)
            prompt = (work/'prompt.md').read_text()
            assert 'The harness alone calls `report_render_step`' in prompt
            assert 'The harness uploads exactly these files, then runs' not in prompt
            assert 'missing validators, missing evidence' in prompt
            assert (path.parent/stage['instructions']).read_text() in prompt
    longform = json.loads((repo/'skills/p-longform/manifest.json').read_text())
    visuals = next(s for s in longform['steps'] if s['id'] == 'build_visuals')
    assert visuals['uses']['optionalProviders'] == ['kie']
    assert 'kie' not in longform['needs']['providers']
PY
then
  pass "all 13 recipe entry points and real managed prompts carry single-owner reporting; Longform Kie stays optional"
else
  fail "recipe reporting instructions" "entry point, prompt ownership or optional-provider contract failed"
fi

# Run: bash test/run-tests.sh --stage-range
# Hermetic stage-range regression group: fake engine/report/upload functions and
# an in-memory HTTP opener. No services, credentials, installs or live network.
stage_range_tests() {
  python3 - "$REPO_DIR" "$TEST_SUITE_BASH" <<'PY'
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.request import Request

repo = Path(sys.argv[1])
# The suite's own bash (see TEST_SUITE_BASH): the scripts below use here-docs
# and here-strings, which /bin/bash 3.2 would park in the system temp dir.
suite_bash = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "bash"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("stage", repo / "bin/cfw-render-stage.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class StageRangeTests(unittest.TestCase):
    def order(self, **changes):
        manifest = json.loads((repo / "test/fixtures/manifests/harness-3step/manifest.json").read_text())
        result = {"id": "order-test", "attempt": {"id": "attempt-test"},
                  "recipe": "harness-3step", "kind": "video", "brandId": "brand-test",
                  "manifest": manifest, "taskOrder": {"brand": {"slug": "brand-test"}}}
        result.update(changes)
        return result

    def bounds(self, start="a", end="b"):
        return {"fromStepId": start, "toStepId": end}

    def harness(self, order, outer=False, missing="", reject="", directive=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "order.json").write_text(json.dumps(order))
            (root / "reports").write_text("")
            # Source only these existing function definitions, not the worker tick.
            worker = (repo / "bin/cfw-render.sh").read_text()
            functions = worker[worker.index("sanitize_slug() {"):worker.index("\nspawn_pids=()")]
            (root / "worker-functions.sh").write_text(functions)
            (root / "bin").mkdir()
            (root / "bin/cfw-render-checkpoint.py").write_bytes((repo / "bin/cfw-render-checkpoint.py").read_bytes())
            report = root / "bin/cfw-render-report.sh"
            report.write_text('#!/bin/bash\nprintf "%s\\n" "$1" >> "$TEST_ROOT/final-calls"\n')
            report.chmod(0o755)
            script = r'''
set -euo pipefail
source "$REPO/bin/cfw-render-harness.sh"
cr_log() { :; }
cr_engine_detect() { echo test; }
cr_harness_heartbeat_start() { :; }
cr_harness_heartbeat_stop() { :; }
cr_h_run_with_timeout() { shift; "$@"; }
cr_h_stage_inputs() { :; }
cr_h_build_prompt() { : > "$2/prompt.md"; }
cr_engine_limit_detect() { return 1; }
cr_engine_limit_until() { :; }
cr_engine_run() {
  [[ "$CFW_STEP_ID" == "$MISSING" ]] && return 0
  local save
  for save in $CFW_STEP_SAVES; do
    printf 'saved bytes' > "$3/saves/${save/:/.}"
  done
}
cr_h_upload_with_retry() { echo https://media.cfw.social/result; }
cr_report_step() {
  python3 - "$4" "$5" "$6" "$TEST_ROOT/reports" <<'REPORT'
import json,sys
with open(sys.argv[4], "a") as f:
    f.write(json.dumps({"seq": int(sys.argv[1]), "event": sys.argv[2], **json.loads(sys.argv[3])}) + "\n")
REPORT
  if [[ "$5" == attempt_completed && "$REJECT" == offline ]]; then return 75; fi
  if [[ "$5" == attempt_completed && "$REJECT" == reject ]]; then
    echo '{"ok":false,"code":"invalid_stage_range","directive":"continue"}'
  elif [[ "$5" == attempt_completed && "$REJECT" == schema ]]; then
    echo '{"ok":false,"code":"invalid_params","error":"Invalid report schema"}'
  elif [[ "$5" == attempt_completed && "$REJECT" == malformed_ack ]]; then
    echo '{"ok":"false","directive":"continue"}'
  elif [[ "$5" == step_completed && -n "$DIRECTIVE" ]]; then
    printf '{"ok":true,"directive":"%s"}' "$DIRECTIVE"
  else echo '{"ok":true,"directive":"continue"}'; fi
}
if [[ "$OUTER" == 1 ]]; then
  source "$TEST_ROOT/worker-functions.sh"
  # WI2.45: spawn_director calls cr_select_deliverables from the shared lib.
  # shellcheck disable=SC1091
  source "$REPO/bin/cfw-render-lib.sh"
  cr_recipe_needs_heygen() { return 1; }
  cr_verify_skills_bundle() { return 0; }
  cr_keep_output_dir() { echo "$TEST_ROOT/kept"; }
  cr_recent_append() { :; }
  SELF_DIR="$TEST_ROOT/bin"
  JOURNAL="$TEST_ROOT/journal"
  spawn_director "$(cat "$TEST_ROOT/order.json")"
else
  cr_harness_run "$TEST_ROOT/order.json" "$TEST_ROOT" "$TEST_ROOT/recipe"
fi
'''
            env = {"PATH": str(Path(sys.executable).parent) + os.pathsep + os.defpath,
                   "TMPDIR": os.environ.get("TMPDIR", "/tmp"),   # bash here-documents need it
                   "HOME": directory, "TEST_ROOT": directory, "REPO": str(repo),
                   "OUTER": str(int(outer)), "MISSING": missing, "REJECT": reject,
                   "DIRECTIVE": directive, "CFW_WORKER_ID": "test-worker", "CFW_API_BASE": "",
                   "CFW_RENDER_WORKER_KEY": "", "CFW_RENDER_STATE_DIR": directory,
                   "CFW_RENDER_LOG_DIR": directory, "CFW_RENDER_SCRATCH": str(root / "scratch"),
                   "CFW_RENDER_SKILLS_DIR": str(root / "skills")}
            result = subprocess.run([suite_bash, "--noprofile", "--norc", "-c", script],
                                    env=env, text=True, capture_output=True, timeout=30)
            events = [json.loads(line) for line in (root / "reports").read_text().splitlines()]
            completed = (root / "final-calls").read_text() if (root / "final-calls").exists() else ""
            return result, events, completed

    def test_inclusive_range_and_stop(self):
        for changes, expected in [
            ({"stageRange": self.bounds("a", "a"), "stopAfterStepId": "a"}, ["a"]),
            ({"stopAfterStepId": "a"}, ["a"]),
            ({"stageRange": self.bounds("b", "b")}, []),
        ]:
            with self.subTest(changes=changes):
                result, events, _ = self.harness(self.order(**changes))
                self.assertEqual(result.returncode, 25, result.stderr)
                self.assertEqual([e["stepId"] for e in events if e["event"] == "step_started"], expected)
                self.assertEqual(events[-1]["event"], "attempt_completed")

    def test_resume_clamp_and_final(self):
        order = self.order(stageRange=self.bounds("b", "c"), resumeFromStepId="a")
        result, events, _ = self.harness(order)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([e["stepId"] for e in events if e["event"] == "step_started"], ["c"])
        self.assertEqual(events[0]["event"], "step_skipped")
        self.assertEqual(json.loads(result.stdout)[0]["id"], "z")

    def test_legacy_spotlight_resume_at_first_server_step(self):
        manifest = json.loads((repo / "skills/p-reels-spotlight/manifest.json").read_text())
        self.assertEqual((manifest["steps"][0]["id"], manifest["steps"][0]["runsOn"]),
                         ("research", "server"))
        order = self.order(manifest=manifest, resumeFromStepId="research",
                           inputs={"broll": [{"url": "https://media.cfw.social/test-broll"}]})
        expected = [s["id"] for s in manifest["steps"] if s["runsOn"] == "computer"]
        self.assertEqual(stage.plan(order)["stepIds"], expected)
        self.assertEqual(stage.plan(order)["resume"], "prepare_footage")
        result, events, _ = self.harness(order)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([e["stepId"] for e in events if e["event"] == "step_started"], expected)
        self.assertTrue(all(e.get("stepId") not in ("research", "script") for e in events))

    def test_resume_at_server_step_after_range_never_reruns(self):
        order = self.order(stageRange=self.bounds("a", "a"), resumeFromStepId="review")
        order["manifest"]["steps"].insert(1, {"id": "review", "runsOn": "server"})
        self.assertEqual(stage.plan(order)["stepIds"], [])
        result, events, _ = self.harness(order)
        self.assertEqual(result.returncode, 25, result.stderr)
        self.assertEqual([e["event"] for e in events], ["attempt_completed"])

    def test_completed_range_never_reruns_or_crosses_endpoint(self):
        for changes in [{"resumeFromStepId": "c"},
                        {"resumeFromStepId": "a", "stageRangeCompleted": True}]:
            result, events, _ = self.harness(self.order(stageRange=self.bounds(), **changes))
            self.assertEqual(result.returncode, 25, result.stderr)
            self.assertEqual([e["event"] for e in events], ["attempt_completed"])
        result, events, _ = self.harness(self.order(stageRange=self.bounds("c", "c"), stageRangeCompleted=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([e["event"] for e in events], ["attempt_completed"])

    def test_invalid_bounds_fail_before_engine_or_reports(self):
        cases = [{"stageRange": self.bounds("c", "a")}, {"stageRange": self.bounds("missing", "b")},
                 {"stageRange": self.bounds(), "stopAfterStepId": "c"}, {"resumeFromStepId": "missing"}]
        for changes in cases:
            result, events, _ = self.harness(self.order(**changes))
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(events, [])

    def test_endpoint_saves_required_even_without_checks(self):
        result, events, _ = self.harness(self.order(stageRange=self.bounds("a", "a")), missing="a")
        self.assertEqual(result.returncode, 30, result.stderr)
        self.assertEqual(events[-1]["event"], "attempt_failed")
        self.assertNotIn("attempt_completed", [e["event"] for e in events])

    def test_terminal_ack_required(self):
        for reject in ("reject", "offline", "schema", "malformed_ack"):
            result, _, _ = self.harness(self.order(stageRange=self.bounds()), reject=reject)
            self.assertEqual(result.returncode, 1, result.stderr)

    def test_revocation_and_cancel_still_win(self):
        for directive, code in [("cancel", 20), ("stop_after_step", 22), ("superseded", 23)]:
            result, events, _ = self.harness(self.order(stageRange=self.bounds()), directive=directive)
            self.assertEqual(result.returncode, code, result.stderr)
            self.assertNotIn("attempt_completed", [e["event"] for e in events])

    def test_nonfinal_skips_complete_and_final_calls_it(self):
        for end, complete in [("a", ""), ("c", "complete\n")]:
            result, _, completed = self.harness(self.order(stageRange=self.bounds("a", end)), outer=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(completed, complete)
        order = self.order(stageRange=self.bounds())
        del order["manifest"]
        result, events, completed = self.harness(order, outer=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual((events, completed), ([], ""))

    def test_new_output_checksum(self):
        result, events, _ = self.harness(self.order(stageRange=self.bounds("a", "a")))
        self.assertEqual(result.returncode, 25, result.stderr)
        output = next(e["outputs"][0] for e in events if e["event"] == "step_completed")
        self.assertEqual(output["checksum"], "sha256:" + hashlib.sha256(b"saved bytes").hexdigest())

    def test_report_outputs_use_save_id_and_local_outputs_keep_id(self):
        order = self.order()
        result, events, _ = self.harness(order)
        self.assertEqual(result.returncode, 0, result.stderr)
        completed = [e for e in events if e["event"] == "step_completed"]
        self.assertEqual([e["stepId"] for e in completed], ["a", "c"])
        # Validate the actual cr_report_step payload, not a constructed example.
        for event in completed:
            declared = next(s["saves"] for s in order["manifest"]["steps"] if s["id"] == event["stepId"])
            self.assertEqual([o["saveId"] for o in event["outputs"]], [s["id"] for s in declared])
            for output in event["outputs"]:
                self.assertEqual(set(output), {"saveId", "url", "checksum"})
                self.assertIsInstance(output["saveId"], str)
                self.assertTrue(output["url"].startswith("https://media.cfw.social/"))
                self.assertRegex(output["checksum"], r"^sha256:[0-9a-f]{64}$")
        local_outputs = json.loads(result.stdout)
        self.assertEqual([o["id"] for o in local_outputs], ["x", "z"])
        self.assertTrue(all("saveId" not in o for o in local_outputs))

    def saved_order(self):
        return self.order(stageRange=self.bounds("c", "c"), savedOutputs=[
            {"stepId": "a", "saveId": "x", "url": "https://media.cfw.social/a"},
            {"stepId": "b", "saveId": "y", "url": "https://media.cfw.social/b"}])

    def test_restore_all_prior_outputs_and_legacy_checksum(self):
        order = self.saved_order()
        order["savedOutputs"][1]["checksum"] = "sha256:" + hashlib.sha256(b"saved").hexdigest()
        with tempfile.TemporaryDirectory() as directory, patch.object(stage.urllib.request.OpenerDirector, "open", side_effect=lambda *a, **k: io.BytesIO(b"saved")) as fetch:
            restored = stage.restore(order, Path(directory))
            self.assertEqual([o["id"] for o in restored], ["x", "y"])
            self.assertEqual(fetch.call_count, 2)
            self.assertTrue(all(Path(o["path"]).read_bytes() == b"saved" for o in restored))

    def test_restore_audio_uses_harness_media_extension(self):
        order = self.saved_order()
        order['manifest']['steps'][0]['saves'][0]['kind'] = 'audio'
        with tempfile.TemporaryDirectory() as directory, patch.object(stage.urllib.request.OpenerDirector, 'open', side_effect=lambda *a, **k: io.BytesIO(b'saved')):
            restored = stage.restore(order, Path(directory))
            self.assertEqual(Path(restored[0]['path']).suffix, '.mp3')
            self.assertEqual(Path(restored[0]['path']).read_bytes(), b'saved')

    def test_restore_excludes_stale_later_outputs(self):
        order = self.saved_order()
        order["stageRange"] = self.bounds("b", "c")
        order["resumeFromStepId"] = "a"
        order["savedOutputs"][1]["url"] = "https://not-approved.example/stale"
        with tempfile.TemporaryDirectory() as directory, patch.object(stage.urllib.request.OpenerDirector, "open", side_effect=lambda *a, **k: io.BytesIO(b"saved")) as fetch:
            self.assertEqual([o["id"] for o in stage.restore(order, Path(directory))], ["x"])
            self.assertEqual(fetch.call_count, 1)

    def test_invalid_restore_paths_known_ids_and_urls(self):
        for field, value in [("stepId", "../outside"), ("saveId", "unknown"),
                             ("url", "file:///tmp/local"), ("url", "https://unapproved.example/save"),
                             ("url", "http://media.cfw.social/save"), ("checksum", "sha256:bad")]:
            order = self.saved_order()
            order["savedOutputs"][0][field] = value
            with tempfile.TemporaryDirectory() as directory, patch.object(stage.urllib.request.OpenerDirector, "open") as fetch:
                with self.assertRaises(ValueError):
                    stage.restore(order, Path(directory))
                fetch.assert_not_called()
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_restore_symlink_and_checksum_failure_preserve_files(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            root = Path(directory)
            (root / "steps").symlink_to(outside, target_is_directory=True)
            with patch.object(stage.urllib.request.OpenerDirector, "open") as fetch:
                with self.assertRaises(ValueError):
                    stage.restore(self.saved_order(), root)
                fetch.assert_not_called()
            (root / "steps").unlink()
            dest = root / "steps/a/saves/x.json"
            dest.parent.mkdir(parents=True)
            dest.write_bytes(b"previous")
            order = self.saved_order()
            order["savedOutputs"][0]["checksum"] = "sha256:" + "0" * 64
            with patch.object(stage.urllib.request.OpenerDirector, "open", side_effect=lambda *a, **k: io.BytesIO(b"wrong")):
                with self.assertRaises(ValueError):
                    stage.restore(order, root)
            self.assertEqual(dest.read_bytes(), b"previous")
            self.assertEqual(list(dest.parent.iterdir()), [dest])

    def test_redirect_policy_including_loopback_seam(self):
        handler = stage.MediaRedirect("", "")
        req = Request("https://media.cfw.social/first")
        for url in ("http://media.cfw.social/next", "https://other.example/next", "file:///tmp/next",
                    "https://user:pass@media.cfw.social/next", "https://media.cfw.social:444/next"):
            with self.assertRaises(ValueError):
                handler.redirect_request(req, None, 302, "", {}, url)
        self.assertEqual(handler.redirect_request(req, None, 302, "", {}, "https://media.cfw.social/next").full_url,
                         "https://media.cfw.social/next")
        self.assertTrue(stage.approved_url("https://custom.example/save", "https://custom.example"))
        self.assertFalse(stage.approved_url("http://127.0.0.1:1234/save"))
        handler = stage.MediaRedirect("", "http://127.0.0.1:1234")
        self.assertIsNotNone(handler.redirect_request(req, None, 302, "", {}, "http://127.0.0.1:1234/save"))
        with self.assertRaises(ValueError):
            handler.redirect_request(req, None, 302, "", {}, "http://127.0.0.1:1235/save")

    def test_capabilities_and_version(self):
        result = subprocess.run(["bash", "--noprofile", "--norc", "-c", '''
source "$1/bin/cfw-render-engine.sh"
cr_engine_manifests_json() { echo '[]'; }
cr_engines_json() { echo '[]'; }
cr_engine_capabilities_json codex "$1/skills"
''', "test", str(repo)], text=True, capture_output=True, check=True,
            env={"PATH": str(Path(sys.executable).parent) + os.pathsep + os.defpath,
                 "TMPDIR": os.environ.get("TMPDIR", "/tmp")})
        self.assertEqual(json.loads(result.stdout)["features"], ["stage-range-v1"])
        self.assertEqual((repo / "VERSION").read_text().strip(), "1.1.0")
        # Exercise only the bin copy line against a disposable destination;
        # never execute installer setup, launchctl or provider calls here.
        lines = (repo / "install/install.sh").read_text().splitlines()
        copies = [line for line in lines if line.startswith('cp -a ') and line.endswith('"$PREFIX/bin/"')]
        self.assertEqual(len(copies), 1)
        with tempfile.TemporaryDirectory(prefix="cfw-stage-package-") as tmp:
            (Path(tmp) / "bin").mkdir()
            subprocess.run(["bash", "--noprofile", "--norc", "-c", copies[0]], check=True,
                env={"PATH": os.defpath, "REPO_DIR": str(repo), "PREFIX": tmp})
            for helper in ("cfw-render-stage.py", "cfw-render-redact.py"):
                self.assertEqual((Path(tmp) / "bin" / helper).read_bytes(), (repo / "bin" / helper).read_bytes())


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
}

if stage_range_tests; then
  pass "stage-range: hermetic regression group"
else
  fail "stage-range" "hermetic regression group failed"
fi
if [[ "${1:-}" == --stage-range ]]; then
  (( FAILURES == 0 )); exit $?
fi

recent_identity_cases() {
  python3 - "$REPO_DIR" <<'PY'
import datetime, json, os, pathlib, signal, subprocess, sys, tempfile
repo = pathlib.Path(sys.argv[1])
source = (repo/'bin/cfw-render.sh').read_text()
functions = source[source.index('sanitize_slug() {'):source.index('# [M2-04] Claims with capacity')]
with tempfile.TemporaryDirectory(prefix='cfw-recent-') as tmp:
    root = pathlib.Path(tmp)
    (root/'logs with spaces/runs').mkdir(parents=True)
    (root/'state').mkdir()
    director = root/'director'
    director.write_text('''#!/bin/bash
printf '%s' "$TEST_OUTCOME" > .outcome
printf 'synthetic transcript %s\\n' "$TEST_ATTEMPT"
# Completion must not rediscover identity from this now-reused claim file.
printf '{"id":"wrong-order","attempt":{"id":"wrong-attempt"}}' > order.json
''')
    director.chmod(0o700)
    # TMPDIR: bash writes here-documents to $TMPDIR (else /tmp, which the runner
    # sandbox refuses); hand the runner's choice through to these minimal envs.
    env = {'PATH': os.environ['PATH'], 'TMPDIR': os.environ.get('TMPDIR', '/tmp'), 'HOME': str(root), 'REPO': str(repo),
        'TEST_ROOT': str(root), 'CFW_RENDER_SCRATCH': str(root/'scratch'),
        'CFW_RENDER_STATE_DIR': str(root/'state'), 'CFW_RENDER_LOG_DIR': str(root/'logs with spaces'),
        'CFW_RENDER_SKILLS_DIR': str(root/'skills'), 'CFW_RENDER_COMPUTER_NAME': 'Synthetic Mac',
        'CFW_WORKER_ID': 'synthetic-worker', 'CFW_API_BASE': 'http://unused.invalid',
        'CFW_RENDER_WORKER_KEY': 'synthetic-key', 'CFW_RENDER_DIRECTOR_CMD': str(director),
        'CFW_RENDER_TIMEOUT_IMAGE': '60', 'CFW_RENDER_TIMEOUT_VIDEO': '60',
        'CFW_RENDER_GATE_FAIL_CAP': '1', 'CFW_RENDER_FANOUT_MODELS': '',
        'CFW_RENDER_OLLAMA_KEYS_FILE': str(root/'absent'), 'CFW_RENDER_KEEP_OUTPUTS': '0',
        'TEST_OUTCOME': 'blocked', 'TEST_ATTEMPT': 'attempt-A', 'TEST_GATE': '', 'TEST_HARNESS_RC': '30'}
    setup = '''
set -u
SELF_DIR="$REPO/bin"
source "$SELF_DIR/cfw-render-lib.sh"
RUNS_DIR="$CFW_RENDER_LOG_DIR/runs"
JOURNAL="$CFW_RENDER_STATE_DIR/journal.tsv"
cr_recipe_needs_heygen() { [[ "$TEST_GATE" == provider ]]; }
cr_verify_skills_bundle() { [[ "$TEST_GATE" != integrity ]]; }
cr_mcp_call() { return 0; }
cr_event() { :; }
cr_heartbeat_start() { :; }
cr_heartbeat_stop() { :; }
cr_keep_output_dir() { echo "$TEST_ROOT/kept/$2"; }
cr_harness_run() { return "$TEST_HARNESS_RC"; }
# Force transcript allocations into one clock second, but leave observed UTC
# starts/finishes real. No sleeps/timing assumptions in the collision test.
date() { if [[ "${1:-}" == +%s ]]; then echo 1234567890; else command date "$@"; fi; }
'''
    def run(script, **extra):
        p = subprocess.Popen(['bash', '-c', setup + script], env={**env, **extra},
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            out, err = p.communicate(timeout=30)
            return p.returncode, out, err
        finally:
            # Only this test session, never a name-based kill of real workers.
            try: os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            p.wait()
    claim = {'id': 'order-1', 'shortCode': 'R-FAIL', 'brandId': 'b1', 'brandName': 'Brand A',
             'taskOrder': {'brand': {'slug': 'brand-a'}, 'credentials': {'test': 'synthetic-provider-secret'}},
             'recipe': 'reel', 'kind': 'image', 'attempt': {'id': 'attempt-A'}, 'attemptId': 'wrong-flat-id',
             'reason': 'private failure detail', 'providerKeys': ['synthetic-provider-secret'],
             'unrelated': 'do-not-copy', 'startedAt': '1999-01-01T00:00:00Z', 'directorLog': 'invented.out'}
    fields = set('shortCode brand result finishedAt orderId attemptId brandSlug recipe kind reason startedAt directorLog'.split())
    def rows(): return [json.loads(s) for s in (root/'state/recent.ndjson').read_text().splitlines()]
    def spawn(order, rc=0, **extra):
        before = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        result, out, err = run(functions + '\nspawn_director "$TEST_CLAIM"\nrc=$?\ncr_status_write\nexit "$rc"\n',
                               TEST_CLAIM=json.dumps(order), **extra)
        assert result == rc, (result, rc, err)
        row = rows()[-1]
        assert set(row) == fields, row
        assert before <= datetime.datetime.fromisoformat(row['startedAt'].replace('Z', '+00:00')) <= datetime.datetime.now(datetime.timezone.utc)
        assert row['attemptId'] == order.get('attempt', {}).get('id', order.get('attemptId'))
        assert row['orderId'] == order['id'] and row['recipe'] == order['recipe']
        for path in ('recent.ndjson', 'status.json'):
            data = (root/'state'/path).read_text()
            assert all(s not in data for s in ('synthetic-provider-secret', 'private failure detail', 'do-not-copy', 'wrong-order', 'wrong-attempt'))
            assert (root/'state'/path).stat().st_mode & 0o777 == 0o600
        return row
    a = spawn(claim)
    assert a['result'] == 'failed' and a['directorLog']
    assert (root/'scratch/brand-a/order-1').is_dir()
    first_log = root/'logs with spaces/runs'/a['directorLog']
    first_bytes = first_log.read_bytes()
    assert first_bytes == b'synthetic transcript attempt-A\n'
    b = spawn({**claim, 'attempt': {'id': 'attempt-B'}}, TEST_OUTCOME='complete', TEST_ATTEMPT='attempt-B')
    assert b['result'] == 'done' and b['brand'] == 'Brand A' and b['brandSlug'] == 'brand-a'
    assert not (root/'scratch/brand-a/order-1').exists()
    assert rows()[:2] == [a, b]
    assert a['directorLog'] != b['directorLog']
    assert all(r['directorLog'].startswith('order-1-1234567890-') and r['directorLog'].endswith('.out') for r in (a,b))
    assert first_log.read_bytes() == first_bytes
    assert (root/'logs with spaces/runs'/b['directorLog']).read_bytes() == b'synthetic transcript attempt-B\n'
    assert first_log.stat().st_mode & 0o777 == 0o600
    status = json.loads((root/'state/status.json').read_text())
    assert status['recent'] == [b, a]
    for gate in ('provider', 'integrity', 'brand'):
        order = {**claim, 'id': 'gate-'+gate}
        if gate == 'brand': order.update(brandId='', taskOrder={})
        r = spawn(order, rc=1, TEST_GATE=gate)
        assert r['result'] == 'failed' and r['directorLog'] is None
    for code, outcome in ((20,'stopped'), (21,'stopped'), (22,'stopped'), (23,'failed'), (24,'stopped'), (25,'done'), (30,'failed'), (31,'failed')):
        r = spawn({**claim, 'id': 'harness-'+str(code), 'manifest': {'steps': []}}, TEST_HARNESS_RC=str(code))
        assert r['result'] == outcome and r['directorLog'] is None
        if code in (22,23,24): assert not (root/'scratch/brand-a'/('harness-'+str(code))).exists()
    # Bad identifiers are refused before either scratch or a transcript exists.
    count = len(rows())
    for oid in ('../escape', 'bad/name', 'bad\\name', 'bad id', '.hidden'):
        rc, _, _ = run(functions + '\nspawn_director "$TEST_CLAIM"\n', TEST_CLAIM=json.dumps({**claim, 'id': oid}))
        assert rc == 1 and len(rows()) == count
    assert not (root/'escape').exists()
    # No Director or heartbeat starts when exclusive allocation fails, and no
    # shared-name fallback is created. Cover absent, non-directory and readonly.
    (root/'not-directory').write_text('untouched')
    (root/'readonly/runs').mkdir(parents=True)
    (root/'readonly/runs').chmod(0o500)
    try:
        for folder in ('missing', 'not-directory', 'readonly'):
            r = spawn({**claim, 'id': 'allocation-'+folder}, rc=1, CFW_RENDER_LOG_DIR=str(root/folder))
            assert r['result'] == 'failed' and r['directorLog'] is None
            assert not (root/'scratch/brand-a'/('allocation-'+folder)/'.outcome').exists()
        assert (root/'not-directory').read_text() == 'untouched'
        assert not list((root/'readonly/runs').iterdir())
    finally:
        (root/'readonly/runs').chmod(0o700)
    # Old callers keep their file-derived identity but never guess start/log.
    legacy = root/'legacy.json'
    legacy.write_text(json.dumps(claim))
    rc, _, err = run('cr_recent_append "$TEST_ROOT/legacy.json" complete fallback\n')
    assert rc == 0, err
    assert rows()[-1]['attemptId'] == 'attempt-A'
    assert rows()[-1]['startedAt'] is None and rows()[-1]['directorLog'] is None
    rc, _, err = run('cr_recent_append "" blocked legacy\n')
    assert rc == 0, err
    r = rows()[-1]
    assert r['orderId'] == 'legacy' and all(r[k] is None for k in fields - {'orderId','result','finishedAt'})
    # Explicit invalid/missing identity cannot fall back to stale scratch.
    for identity in ('', '[]', '{', json.dumps({'orderId': {'secret': 'do-not-copy'}, 'brand': ['do-not-copy'],
            'startedAt': 'not-a-date', 'directorLog': '../outside.out', 'reason': 'private failure detail'})):
        rc, _, err = run('cr_recent_append "$TEST_ROOT/legacy.json" blocked fallback "$TEST_IDENTITY"\n', TEST_IDENTITY=identity)
        assert rc == 0, err
        r = rows()[-1]
        assert all(r[k] is None for k in fields - {'result','finishedAt'}), r
    # Fifth argument is a distinct owner-safe summary, never identity JSON.
    identity = json.dumps({'orderId': 'reason-order', 'attemptId': 'reason-attempt'})
    rc, _, err = run('cr_recent_append "" failed reason-order "$TEST_IDENTITY" "missing input cfw_render_synthetic_test_key"\n', TEST_IDENTITY=identity)
    assert rc == 0, err
    r = rows()[-1]
    assert r['attemptId'] == 'reason-attempt' and r['reason'] == 'missing input cfw_render_[redacted]'
    rc, _, err = run('cr_recent_append "" complete reason-order "$TEST_IDENTITY" "not a failure"\n', TEST_IDENTITY=identity)
    assert rc == 0 and rows()[-1]['reason'] is None, err
    assert len(rows()) <= 50
    print('PASS: attempt identity survives reuse/cleanup; nested IDs, early gates, harness, legacy/null and secret exclusions')
    print('PASS: same-second exclusive transcripts preserve bytes; spaced paths, unsafe IDs and allocation failures')
    # Consumed by the desktop regression: actual worker-produced status, no logs.
    print('STATUS_FIXTURE=' + json.dumps(status))
PY
}
if [[ "${1:-}" == --recent-identity ]]; then
  recent_identity_cases && (( FAILURES == 0 ))
  exit $?
fi

# Existing M3-05a-3 update case, selectable without starting workers/services.
# This is file-copy coverage, NOT native app/updater or LaunchAgent acceptance.
installer_update_case() {
  python3 - "$REPO_DIR" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, tempfile
repo = pathlib.Path(sys.argv[1])
pin = next(d for d in json.loads((repo/'config/agent-guides.json').read_text())['documents']
           if d['path'] == 'lib/render-debug.md')
assert hashlib.sha256((repo/pin['path']).read_bytes()).hexdigest() == pin['sha256']
with tempfile.TemporaryDirectory(prefix='cfw-update-test-') as tmp:
    root = pathlib.Path(tmp)
    guards = root/'guards'; guards.mkdir()
    # Defense in depth: even a regressed skip flag must not touch real services.
    for name in ('launchctl', 'curl', 'claude', 'codex'):
        stub = guards/name
        stub.write_text('#!/bin/bash\nprintf "%s\\n" "$0" >> "$HOME/unexpected-command"\nexit 97\n')
        stub.chmod(0o700)
    for guide_state in ('missing', 'stale'):
        home = root/guide_state; home.mkdir()
        prefix = home/'CFW Render/app'
        (prefix/'bin').mkdir(parents=True)
        (prefix/'lib').mkdir()
        (prefix/'config').mkdir()
        for name in ('cfw-render.sh', 'cfw-render-lib.sh'):
            (prefix/'bin'/name).write_text('old worker\n')
        if guide_state == 'stale':
            (prefix/'lib/render-debug.md').write_text('old guide\n')
        # Only synthetic settings/evidence, all confined to this test directory.
        preserved = {
            'CFW Render/app/config/local-only.json': b'{"local":true}\n',
            '.cfw-render/app-settings.json': b'{"autoUpdate":false,"workerSyncedVersion":"old"}\n',
            '.cfw-render/cfw-render.env': b'CFW_RENDER_WORKER_KEY=synthetic-only\n',
            '.cfw-render/worker-id': b'synthetic-worker\n',
            '.cfw-render/recent.ndjson': b'{"attemptId":"attempt-A"}\n',
            '.cfw-render/status.json': b'{"schema":1,"recent":[]}\n',
            '.cfw-render/scratch/brand/order/order.json': b'{"id":"order"}\n',
            'CFW Render/logs/runs/order-123-old.out': b'synthetic prior evidence\n',
            'CFW Render/outputs/brand/output.txt': b'synthetic output\n',
            'Library/LaunchAgents/com.cfw.render.plist': b'synthetic plist, never loaded\n',
        }
        for name, data in preserved.items():
            path = home/name; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data); path.chmod(0o600)
        env = {'HOME': str(home), 'PATH': str(guards)+os.pathsep+os.environ['PATH'],
               'TMPDIR': os.environ.get('TMPDIR', '/tmp'),
               'CFW_RENDER_SKIP_LAUNCHCTL': '1', 'CFW_RENDER_INSTALL_NO_LAUNCHCTL': '1'}
        with (home/'stdin').open('w+b') as stdin:
            stdin.write(b'KEEP-THIS-LINE\n'); stdin.seek(0)
            result = subprocess.run(['bash', str(repo/'install/install.sh'), '--mode', 'byoa',
                '--non-interactive', '--from-app', '--update'], env=env, cwd=home,
                stdin=stdin, capture_output=True, timeout=60)
            assert result.returncode == 0, (guide_state, result.returncode, result.stderr.decode())
            assert stdin.read() == b'KEEP-THIS-LINE\n', 'update consumed stdin'
        assert [json.loads(line) for line in result.stdout.splitlines()] == [
            {'step': 'ready', 'state': 'done', 'message': 'Updated'}]
        for name in ('bin/cfw-render.sh', 'bin/cfw-render-lib.sh', 'VERSION',
                     'lib/render-debug.md', 'lib/render-debug.py', 'bin/cfw-render-redact.py',
                     'bin/cfw-render-stage.py', 'config/agent-guides.json'):
            assert (prefix/name).read_bytes() == (repo/name).read_bytes(), name
        assert hashlib.sha256((prefix/pin['path']).read_bytes()).hexdigest() == pin['sha256']
        for name, data in preserved.items():
            assert (home/name).read_bytes() == data, name
            assert (home/name).stat().st_mode & 0o777 == 0o600, name
        assert not (home/'unexpected-command').exists(), 'external command attempted'
        print('PASS: update from '+guide_state+' guide restores pinned guide and worker; settings/state/evidence preserved; stdin untouched; no services')
PY
}
if [[ "${1:-}" == --installer-update ]]; then
  installer_update_case && (( FAILURES == 0 ))
  exit $?
fi

debug_lookup_case() {
  python3 - "$REPO_DIR" <<'PY'
import datetime, importlib.util, json, pathlib, subprocess, sys, tempfile
repo = pathlib.Path(sys.argv[1])
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('render_debug', repo/'lib/render-debug.py')
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
with tempfile.TemporaryDirectory(prefix='cfw-debug-lookup-') as tmp:
    root = pathlib.Path(tmp); logs = root/'custom logs'; runs = logs/'runs'; runs.mkdir(parents=True)
    scratch = root/'scratch'; folder = scratch/'brand-a/o1'; folder.mkdir(parents=True)
    def iso(epoch): return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isoformat()
    identity = dict(orderId='o1', attemptId='a1', brandSlug='brand-a', startedAt=iso(100), finishedAt=iso(110))
    def locate(**changes): return mod.locate({**identity, **changes}, logs, scratch)
    for name in ('o1-105.out', 'o1-205.out', 'o10-105.out'):
        (runs/name).write_text('synthetic evidence')
    order = dict(id='o1', attempt=dict(id='a1'), taskOrder=dict(brand=dict(slug='brand-a'), credentials='DO-NOT-OUTPUT'))
    (folder/'order.json').write_text(json.dumps(order))
    found = locate()
    assert found['directorLog'] == str(runs/'o1-105.out') and found['scratchDirectory'] == str(folder)
    assert 'DO-NOT-OUTPUT' not in json.dumps(found)
    for changes in ({'startedAt': None}, {'finishedAt': iso(99)}, {'orderId': '../o1'}):
        assert locate(**changes)['directorLog'] is None
    for changes in ({'brandSlug': '../brand-a'}, {'attemptId': 'a2'}, {'attemptId': None}):
        assert locate(**changes)['scratchDirectory'] is None
    (runs/'o1-105-second.out').write_text('same-second retry')
    assert locate()['directorLog'] is None
    for name in ('o1-105.out', 'o1-105-second.out'):
        assert locate(directorLog=name)['directorLog'] == str(runs/name)
    for name in ('o1-106-missing.out', '../o1-105.out', 'o10-105.out'):
        assert locate(directorLog=name)['directorLog'] is None
    (runs/'o1-107.out').symlink_to(runs/'o1-205.out')
    assert locate(directorLog='o1-107.out')['directorLog'] is None
    (root/'linked logs').mkdir(); (root/'linked logs/runs').symlink_to(runs)
    assert mod.locate({**identity, 'directorLog': 'o1-105.out'}, root/'linked logs', scratch)['directorLog'] is None
    order['attempt']['id'] = 'a2'; (folder/'order.json').write_text(json.dumps(order))
    assert locate()['scratchDirectory'] is None
    for invalid in ([], {'attempt': []}, {'taskOrder': []}):
        (folder/'order.json').write_text(json.dumps(invalid))
        assert locate()['scratchDirectory'] is None
    cli = subprocess.run([sys.executable, str(repo/'lib/render-debug.py'), '--log-dir', str(logs), '--scratch-dir', str(scratch)],
        input=json.dumps({**identity, 'directorLog': 'o1-105.out'}), text=True, capture_output=True, check=True)
    assert json.loads(cli.stdout)['directorLog'] == str(runs/'o1-105.out')
print('PASS: exact, legacy, ambiguous, missing, symlink, reused scratch and custom-path debug lookup')
PY
}
if [[ "${1:-}" == --debug-lookup ]]; then
  debug_lookup_case && (( FAILURES == 0 ))
  exit $?
fi
if recent_identity_cases; then pass "frozen identity and owner-safe reason"; else fail "recent identity" "regression failed"; fi
if installer_update_case; then pass "pinned helpers survive update"; else fail "installer update" "regression failed"; fi
if debug_lookup_case; then pass "contained exact-attempt lookup"; else fail "debug lookup" "regression failed"; fi

FAKE_BIN="$(mktemp -d)"
cp "$TEST_DIR/fake-claude.sh" "$FAKE_BIN/claude"
chmod +x "$FAKE_BIN/claude"

# [M3-01] The worker pauses on battery (cr_on_battery → pmset). Every case must
# be independent of the host's power state, so a stub pmset reporting AC power
# is the default for the whole suite; the M3-01a cases flip it via the
# FAKE_PMSET_BATTERY marker file.
FAKE_PMSET_BATTERY="$(mktemp -u)"; export FAKE_PMSET_BATTERY
cat > "$FAKE_BIN/pmset" <<'EOF2'
#!/usr/bin/env bash
if [[ -e "${FAKE_PMSET_BATTERY:-/nonexistent}" ]]; then echo "Now drawing from 'Battery Power'"; else echo "Now drawing from 'AC Power'"; fi
EOF2
chmod +x "$FAKE_BIN/pmset"
export CFW_RENDER_PMSET_CMD="$FAKE_BIN/pmset"

# cr_preflight_chromium looks for a Playwright browser under $HOME (or under
# PLAYWRIGHT_BROWSERS_PATH). The runner sandbox hides the host's cache, so every
# tick would refuse to claim ("no Playwright/Chromium browser found") although
# no case renders with a real browser: engines and Directors are fakes. When
# the inherited environment shows no browser, point the search at a fixture
# layout. A box with a real cache keeps using it, so the preflight cases still
# exercise the real discovery there.
if ! ( source "$REPO_DIR/bin/cfw-render-lib.sh"; cr_preflight_chromium ) >/dev/null 2>&1; then
  FAKE_PLAYWRIGHT="$(mktemp -d)"
  mkdir -p "$FAKE_PLAYWRIGHT/chromium_headless_shell-fixture/chrome-mac"
  printf '#!/usr/bin/env bash\n# test fixture standing in for a Playwright headless shell; never launched\nexit 0\n' \
    > "$FAKE_PLAYWRIGHT/chromium_headless_shell-fixture/chrome-mac/chrome-headless-shell"
  chmod +x "$FAKE_PLAYWRIGHT/chromium_headless_shell-fixture/chrome-mac/chrome-headless-shell"
  export PLAYWRIGHT_BROWSERS_PATH="$FAKE_PLAYWRIGHT"
  echo "note: no Playwright browser is visible to this run; preflight uses the fixture under PLAYWRIGHT_BROWSERS_PATH"
fi

# The worker skips normal claims while the 1-minute load average is above the
# CPU count (cr_capacity_ok). On a busy dev Mac that made the capacity cases
# (25-29) fail with "normal claims skipped, urgent only". Pin the load seam for
# the whole suite so no case depends on what else the host is running; a case
# that needs a busy machine sets CFW_RENDER_CAPACITY_LOAD itself.
export CFW_RENDER_CAPACITY_LOAD=0

OLLAMA_KEYS_FIXTURE="$(mktemp)"
cat > "$OLLAMA_KEYS_FIXTURE" <<'EOF'
OLLAMA_KEY_GOOFY_HUGLE_463_B=test-dummy-key-goofy
OLLAMA_KEY_RECURSING_PIKE_357=test-dummy-key-pike
EOF

MOCK_PORT_BASE=38100
CASE_N=0

order_fixture() {
  # order_fixture <id> <brandId> <kind> -> writes a one-order queue seed to stdout
  local id="$1" brand="$2" kind="$3"
  python3 -c '
import json, sys
oid, brand, kind = sys.argv[1:4]
order = {
    "id": oid, "brandId": brand, "workspaceId": "ws-1", "kind": kind,
    "recipe": "p-reels-spotlight", "status": "queued",
    "taskOrder": {
        "version": 1, "orderId": oid,
        "brand": {"id": brand, "slug": "test-brand", "brief": "test brand"},
        "kind": kind, "recipe": "p-reels-spotlight", "workspaceId": "ws-1",
        "intent": "test render", "ingredients": [],
        "targets": ["instagram", "tiktok", "youtube", "threads"],
        "acceptance": {"gate": "c-shorts-qa-gate"},
    },
    "priority": 0, "attempts": 1,
}
print(json.dumps([order]))
' "$id" "$brand" "$kind"
}

empty_queue() { echo '[]'; }

order_fixture_heygen() {
  # order_fixture_heygen <id> <brandId> <kind> [cred-json]
  # [CFW-313] Same shape as order_fixture() but on a `*-heygen` recipe, with
  # an optional taskOrder.credentials.heygen literal (compact JSON, NO
  # spaces — this string travels through run_case's unquoted word-split, so
  # a space inside it would split into extra, wrong positional args).
  # Omitting the 4th arg entirely means "this brand has no HeyGen account
  # connected" — taskOrder.credentials.heygen is absent, same as real life.
  local id="$1" brand="$2" kind="$3" cred="${4:-}"
  python3 -c '
import json, sys
oid, brand, kind, cred_raw = sys.argv[1:5]
task = {
    "version": 1, "orderId": oid,
    "brand": {"id": brand, "slug": "test-brand", "brief": "test brand"},
    "kind": kind, "recipe": "p-reels-spotlight-heygen", "workspaceId": "ws-1",
    "intent": "test render", "ingredients": [],
    "targets": ["instagram", "tiktok", "youtube", "threads"],
    "acceptance": {"gate": "c-shorts-qa-gate"},
}
if cred_raw:
    task["credentials"] = {"heygen": json.loads(cred_raw)}
order = {
    "id": oid, "brandId": brand, "workspaceId": "ws-1", "kind": kind,
    "recipe": "p-reels-spotlight-heygen", "status": "queued",
    "taskOrder": task,
    "priority": 0, "attempts": 1,
}
print(json.dumps([order]))
' "$id" "$brand" "$kind" "$cred"
}

start_mock() {
  # NOTE: must redirect the background server's stdout/stderr away from the
  # inherited pipe — backgrounding inside a `$(...)` command substitution
  # without redirecting keeps that pipe's write end open for the server's
  # whole lifetime, so the substitution never sees EOF and hangs forever.
  local seed_file="$1" state_dir="$2" port="$3"
  python3 "$TEST_DIR/mock-server.py" "$port" "$state_dir" "$seed_file" \
    > "$state_dir/../mock-server.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 50); do
    curl -sS --max-time 1 "http://127.0.0.1:$port/api/v1/mcp" >/dev/null 2>&1 && break
    sleep 0.1
  done
  echo "$pid"
}

# owner_layout <home> — undo run_case's test pins (logs in the state dir, no
# kept copies) so a case sees the real owner defaults under <home>.
owner_layout() {
  unset CFW_RENDER_LOG_DIR CFW_RENDER_KEEP_OUTPUTS
  export "CFW_RENDER_HOME=$1"
}

run_case() {
  # run_case <name> <mode> <order-json-producer> <extra_env...>
  local name="$1" mode="$2" order_producer="$3"; shift 3
  CASE_N=$((CASE_N+1))
  local port=$((MOCK_PORT_BASE + CASE_N))
  local case_dir; case_dir="$(mktemp -d)"
  local seed="$case_dir/queue.json" state="$case_dir/mockstate"
  mkdir -p "$state"
  # Intentional word-splitting: order_producer is "fn arg1 arg2 ..." built by
  # the call site (e.g. "order_fixture order-happy-1 brand-1 video").
  # shellcheck disable=SC2086
  $order_producer > "$seed"

  local mock_pid; mock_pid="$(start_mock "$seed" "$state" "$port")"

  local cr_state="$case_dir/cr-state" cr_scratch="$case_dir/cr-scratch"
  mkdir -p "$cr_state" "$cr_scratch"

  (
    export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
    export CFW_API_BASE="http://127.0.0.1:$port"
    export CFW_RENDER_TEST_MEDIA_BASE_URL="$CFW_API_BASE"
    export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
    export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
    export CFW_RENDER_STATE_DIR="$cr_state"
    export CFW_RENDER_LOG_DIR="$cr_state" CFW_RENDER_KEEP_OUTPUTS=0
    export CFW_RENDER_SCRATCH="$cr_scratch"
    export CFW_RENDER_SKILLS_DIR="$case_dir/skills"
    export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
    export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
    export FAKE_DIRECTOR_MODE="$mode"
    export CFW_RENDER_TIMEOUT_VIDEO="${CASE_TIMEOUT_VIDEO:-30}"
    export CFW_RENDER_TIMEOUT_IMAGE="${CASE_TIMEOUT_IMAGE:-30}"
    export CFW_RENDER_CONCURRENCY="${CASE_CONCURRENCY:-1}"
    "$@"
    "$REPO_DIR/bin/cfw-render.sh" --once
  )
  local drainer_exit=$?

  kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null

  : "$name"  # kept for call-site readability; not otherwise referenced
  CASE_STATE="$cr_state"
  CASE_MOCKSTATE="$state"
  CASE_SCRATCH="$cr_scratch"
  CASE_DRAINER_EXIT="$drainer_exit"
}

calls_count() {  # calls_count <tool>
  # NOTE: `grep -c` already prints "0" on no match but exits 1 — a naive
  # `|| echo 0` fallback double-prints ("0\n0") and breaks arithmetic
  # comparisons downstream. Only fall back when the file is genuinely absent.
  local f="$CASE_MOCKSTATE/calls.jsonl"
  [[ -f "$f" ]] || { echo 0; return; }
  grep -c "\"tool\": \"$1\"" "$f"
}

echo "=== Case 1: --dry makes zero tools/call ==="
case_dir_dry="$(mktemp -d)"; mkdir -p "$case_dir_dry/mockstate"
empty_queue > "$case_dir_dry/queue.json"
dry_port=$((MOCK_PORT_BASE + 90))
dry_pid="$(start_mock "$case_dir_dry/queue.json" "$case_dir_dry/mockstate" "$dry_port")"
(
  export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
  export CFW_API_BASE="http://127.0.0.1:$dry_port"
  export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
  export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
  export CFW_RENDER_STATE_DIR="$case_dir_dry/cr-state"
  export CFW_RENDER_LOG_DIR="$case_dir_dry/cr-state" CFW_RENDER_KEEP_OUTPUTS=0
  export CFW_RENDER_SCRATCH="$case_dir_dry/cr-scratch"
  export CFW_RENDER_SKILLS_DIR="$case_dir_dry/skills"
  export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
  "$REPO_DIR/bin/cfw-render.sh" --dry
)
dry_exit=$?
kill "$dry_pid" 2>/dev/null; wait "$dry_pid" 2>/dev/null
if [[ "$dry_exit" == "0" ]]; then pass "--dry exits 0 against a reachable mock"; else fail "--dry exit code" "expected 0, got $dry_exit"; fi
if [[ -f "$case_dir_dry/mockstate/calls.jsonl" ]]; then
  dry_calls="$(wc -l < "$case_dir_dry/mockstate/calls.jsonl" | tr -d ' ')"
else
  dry_calls=0
fi
if [[ "$dry_calls" == "0" ]]; then pass "--dry makes zero tools/call"; else fail "--dry tools/call count" "expected 0, got $dry_calls"; fi

echo "=== Case 2: happy path (video) ==="
run_case "happy-path" "happy" "order_fixture order-happy-1 brand-1 video" true
if [[ "$(calls_count claim_render_order)" -ge 1 ]]; then pass "happy: claim_render_order called"; else fail "happy: claim" "no claim_render_order call"; fi
if [[ "$(calls_count append_render_event)" -ge 3 ]]; then pass "happy: stage events emitted"; else fail "happy: stage events" "expected >=3 append_render_event calls"; fi
if grep -q '"tool": "append_render_event".*"kind": "subagent"' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null; then
  pass "happy: subagent event recorded"
else
  fail "happy: subagent event" "no kind=subagent append_render_event found"
fi
if [[ -f "$CASE_MOCKSTATE/uploads.jsonl" ]] && grep -q "order-happy-1" "$CASE_MOCKSTATE/uploads.jsonl"; then
  pass "happy: upload happened"
else
  fail "happy: upload" "no upload recorded for order-happy-1"
fi
if [[ "$(calls_count complete_render_order)" -ge 1 ]]; then
  pass "happy: complete_render_order called"
else
  fail "happy: complete" "no complete_render_order call"
fi
complete_line="$(grep '"tool": "complete_render_order"' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null | tail -1)"
if echo "$complete_line" | grep -q '"fanout": \["glm-5.2"\]'; then
  pass "happy: models rollup contains fanout model glm-5.2"
else
  fail "happy: models rollup" "fanout model not found in: $complete_line"
fi
# CFW-136: reel completion = video (cover) + cover.png (poster) + per-platform captions.
happy_check="$(printf '%s' "$complete_line" | python3 -c '
import json, sys
try:
    call = json.loads(sys.stdin.read())
except Exception as e:
    print("ERR parse " + str(e)); sys.exit(0)
a = call.get("args", {})
outs = a.get("outputs") or []
caps = a.get("captions") or {}
problems = []
if len(outs) != 2: problems.append("outputs=%d" % len(outs))
if not (outs and outs[0].get("kind") == "video" and outs[0].get("role") == "cover"): problems.append("video not role cover")
if not (len(outs) > 1 and outs[1].get("url", "").endswith("-cover.png") and outs[1].get("kind") == "image" and outs[1].get("role") == "poster"): problems.append("cover.png not role poster")
if a.get("outputUrl") != (outs[0].get("url") if outs else None): problems.append("outputUrl != video")
if sorted(caps.keys()) != ["instagram", "tiktok", "youtube"]: problems.append("caption keys %r" % sorted(caps.keys()))
if "threads" in caps: problems.append("blank threads caption was sent")
if any(not v.strip() for v in caps.values()): problems.append("blank caption value")
if not caps.get("youtube", "").startswith("Day 14 of 30: The 3 AI Tools"): problems.append("youtube title line lost")
print("OK" if not problems else "BAD " + "; ".join(problems) + " :: " + json.dumps(a)[:300])
')"
if [[ "$happy_check" == "OK" ]]; then
  pass "happy: reel payload — video role cover, cover.png role poster, captions lower-cased/non-blank per target (blank threads dropped)"
else
  fail "happy: reel payload" "$happy_check"
fi
if [[ -f "$CASE_MOCKSTATE/uploads.jsonl" ]] && grep -q "cover.png" "$CASE_MOCKSTATE/uploads.jsonl"; then
  pass "happy: cover.png uploaded via /render/upload"
else
  fail "happy: cover.png upload" "cover.png not in uploads.jsonl"
fi
if [[ ! -d "$CASE_SCRATCH/test-brand/order-happy-1" ]]; then
  pass "happy: scratch dir wiped after complete"
else
  fail "happy: scratch wipe" "scratch dir still present"
fi
if grep -q "order-happy-1.*complete" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "happy: journal row outcome=complete"
else
  fail "happy: journal row" "no complete journal row found"
fi
if ! grep -q "kept .* finished file" "$CASE_STATE/cfw-render.log" 2>/dev/null; then
  pass "happy (CFW_RENDER_KEEP_OUTPUTS=0): no local copy kept"
else
  fail "happy (KEEP_OUTPUTS=0): local copy" "a local copy was kept with KEEP_OUTPUTS=0"
fi

echo "=== Case 2g: owner computer (byoa) layout — finished files kept in 'CFW Render/outputs' after CFW accepted them; logs in 'CFW Render/logs' ==="
c2g_root="$(mktemp -d)"
c2g_home="$c2g_root/CFW Render"   # the space is deliberate: the real folder name has one
run_case "byoa-keep" "happy" "order_fixture order-keep-1 brand-1 video" \
  owner_layout "$c2g_home"
if [[ "$(calls_count complete_render_order)" -ge 1 ]]; then
  pass "byoa-keep: complete_render_order called"
else
  fail "byoa-keep: complete" "no complete_render_order call"
fi
c2g_kept="$(find "$c2g_home/outputs/test-brand" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
if [[ "$(basename "$c2g_kept" 2>/dev/null)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_order-keep-1$ ]]; then
  pass "byoa-keep: kept folder is outputs/<brand>/<YYYY-MM-DD>_<order>"
else
  fail "byoa-keep: kept folder" "expected outputs/test-brand/<date>_order-keep-1, found: '$c2g_kept' ($(find "$c2g_root" 2>/dev/null | head -20 | tr '\n' ' '))"
fi
c2g_uploaded="$(grep -c "order-keep-1" "$CASE_MOCKSTATE/uploads.jsonl" 2>/dev/null || true)"
c2g_kept_n="$(find "$c2g_kept" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [[ -n "$c2g_kept" && "$c2g_kept_n" -ge 2 && "$c2g_kept_n" == "$c2g_uploaded" ]]; then
  pass "byoa-keep: every uploaded file kept locally ($c2g_kept_n of $c2g_uploaded, incl. $(find "$c2g_kept" -type f -name '*.png' | wc -l | tr -d ' ') png)"
else
  fail "byoa-keep: kept files" "kept=$c2g_kept_n uploaded=$c2g_uploaded"
fi
if grep -q "order order-keep-1 — kept $c2g_kept_n finished file" "$c2g_home/logs/cfw-render.log" 2>/dev/null \
   && [[ ! -f "$CASE_STATE/cfw-render.log" ]]; then
  pass "byoa-keep: renderer log is in 'CFW Render/logs', not the hidden state dir"
else
  fail "byoa-keep: log location" "logs/: $(ls "$c2g_home/logs" 2>&1 | tr '\n' ' ') state: $(ls "$CASE_STATE" 2>&1 | tr '\n' ' ')"
fi
if compgen -G "$c2g_home/logs/runs/order-keep-1-*.out" >/dev/null; then
  pass "byoa-keep: render transcript in 'CFW Render/logs/runs'"
else
  fail "byoa-keep: transcript" "no logs/runs/order-keep-1-*.out"
fi
if [[ -f "$CASE_STATE/journal.tsv" && ! -d "$CASE_SCRATCH/test-brand/order-keep-1" ]]; then
  pass "byoa-keep: journal stays in the hidden state dir; scratch wiped"
else
  fail "byoa-keep: state/scratch" "journal or scratch wrong"
fi

echo "=== Case 2b: carousel — outputUrls[] + outputs[] (CFW-135) ==="
run_case "carousel" "carousel" "order_fixture order-carousel-1 brand-1 image" true
if [[ "$(calls_count complete_render_order)" == "1" ]]; then
  pass "carousel: exactly one complete_render_order call"
else
  fail "carousel: complete count" "expected 1, got $(calls_count complete_render_order)"
fi
carousel_line="$(grep '"tool": "complete_render_order"' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null | tail -1)"
carousel_check="$(printf '%s' "$carousel_line" | python3 -c '
import json, sys
try:
    call = json.loads(sys.stdin.read())
except Exception as e:
    print("ERR parse " + str(e)); sys.exit(0)
a = call.get("args", {})
urls = a.get("outputUrls") or []
outs = a.get("outputs") or []
ok = (
    len(urls) == 4
    and urls[0].endswith("-slide-1.png") and urls[3].endswith("-carousel.pdf")
    and a.get("outputUrl") == urls[0]
    and len(outs) == 4
    and [o["order"] for o in outs] == [0, 1, 2, 3]
    and [o["kind"] for o in outs] == ["image", "image", "image", "doc"]
    and outs[3]["mimeType"] == "application/pdf"
    and all("brands/brand-1/renders/order-carousel-1/" in u for u in urls)
)
print("OK" if ok else "BAD " + json.dumps(a)[:400])
')"
if [[ "$carousel_check" == "OK" ]]; then
  pass "carousel: outputUrl=cover, outputUrls=4 in order, outputs[] typed (pdf → doc/application/pdf)"
else
  fail "carousel: complete payload" "$carousel_check"
fi
if [[ -f "$CASE_MOCKSTATE/uploads.jsonl" ]] && grep -q "carousel.pdf" "$CASE_MOCKSTATE/uploads.jsonl"; then
  pass "carousel: PDF uploaded via /render/upload"
else
  fail "carousel: PDF upload" "carousel.pdf not in uploads.jsonl"
fi
# No append_render_event may follow the complete call (the order is terminal).
post_complete="$(python3 -c '
import json, sys
seen = False; late = 0
for line in open(sys.argv[1]):
    c = json.loads(line)
    if c.get("tool") == "complete_render_order": seen = True; continue
    if seen and c.get("tool") == "append_render_event": late += 1
print(late)
' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null || echo 99)"
if [[ "$post_complete" == "0" ]]; then
  pass "carousel: no stage event after complete"
else
  fail "carousel: post-complete event" "$post_complete append_render_event call(s) after complete"
fi
if grep -q "order-carousel-1.*complete" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "carousel: journal row outcome=complete"
else
  fail "carousel: journal row" "no complete journal row found"
fi

echo "=== Case 2c: no captions.json — WARN, still completes, no captions key (CFW-136) ==="
run_case "no-captions" "no-captions" "order_fixture order-nocap-1 brand-1 video" true
if [[ "$(calls_count complete_render_order)" == "1" ]]; then
  pass "no-captions: complete_render_order still called (server falls back to copy/intent)"
else
  fail "no-captions: complete count" "expected 1, got $(calls_count complete_render_order)"
fi
nocap_line="$(grep '"tool": "complete_render_order"' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null | tail -1)"
if printf '%s' "$nocap_line" | python3 -c 'import json,sys; a=json.loads(sys.stdin.read()).get("args",{}); sys.exit(0 if "captions" not in a else 1)'; then
  pass "no-captions: no captions key sent (never an empty map)"
else
  fail "no-captions: captions key" "an empty/absent captions.json must not send a captions key: $nocap_line"
fi
if grep -q "order-nocap-1.*complete" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "no-captions: journal row outcome=complete"
else
  fail "no-captions: journal row" "no complete journal row found"
fi

echo "=== Case 2d: 6 MiB reel via the presigned path (CFW-144, default mode) ==="
run_case "large-presign" "large" "order_fixture order-large-1 brand-1 video" true
presign_check="$(python3 - "$CASE_MOCKSTATE/uploads.jsonl" <<'PY'
import json, sys
try:
    rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except Exception as e:
    print("ERR " + str(e)); sys.exit(0)
rows = [r for r in rows if r.get("orderId") == "order-large-1"]
problems = []
by = {r["files"][0]: r for r in rows}
if set(by) != {"out.mp4", "cover.png"}: problems.append("files %r" % sorted(by))
if any(r.get("via") != "presign" for r in rows): problems.append("not every file went via presign: %r" % [(r["files"], r.get("via")) for r in rows])
if by.get("out.mp4", {}).get("bytes") != 6291456: problems.append("reel bytes %r" % by.get("out.mp4", {}).get("bytes"))
if any(r.get("puts") != 1 for r in rows): problems.append("PUT retried (ETag/MD5 check should pass first try): %r" % [(r["files"], r.get("puts")) for r in rows])
print("OK" if not problems else "BAD " + "; ".join(problems))
PY
)"
if [[ "$presign_check" == "OK" ]]; then
  pass "large: reel (6 MiB) + cover both delivered via upload-url → PUT → upload-complete, bytes verified, ETag=MD5 matched on the first PUT"
else
  fail "large: presign delivery" "$presign_check"
fi
if [[ "$(calls_count complete_render_order)" -eq 1 ]]; then
  pass "large: exactly one complete_render_order"
else
  fail "large: complete" "expected 1 complete_render_order call, got $(calls_count complete_render_order)"
fi
complete_line="$(grep '"tool": "complete_render_order"' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null | tail -1)"
if echo "$complete_line" | grep -q 'brands/brand-1/renders/order-large-1/' && echo "$complete_line" | grep -q '"role": "poster"'; then
  pass "large: completion carries namespaced CDN URLs + the poster role (report contract unchanged)"
else
  fail "large: completion payload" "$complete_line"
fi
if grep -q "order-large-1.*complete" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "large: journal row outcome=complete"
else
  fail "large: journal row" "no complete journal row found"
fi

echo "=== Case 2e: auto mode — small file multipart, large file presign (CFW-144) ==="
run_case "large-auto" "large" "order_fixture order-auto-1 brand-1 video" export CFW_RENDER_UPLOAD_MODE=auto
auto_check="$(python3 - "$CASE_MOCKSTATE/uploads.jsonl" <<'PY'
import json, sys
try:
    rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except Exception as e:
    print("ERR " + str(e)); sys.exit(0)
by = {r["files"][0]: r.get("via") for r in rows if r.get("orderId") == "order-auto-1"}
print("OK" if by == {"out.mp4": "presign", "cover.png": "multipart"} else "BAD %r" % by)
PY
)"
if [[ "$auto_check" == "OK" ]]; then
  pass "auto: cover.png (≤4 MiB) via multipart, out.mp4 (6 MiB) via presign"
else
  fail "auto: routing" "$auto_check"
fi
if [[ "$(calls_count complete_render_order)" -eq 1 ]]; then pass "auto: completed"; else fail "auto: complete" "no complete call"; fi

echo "=== Case 2f: multipart-only mode with a 6 MiB reel → platform 413, order blocked, no completion (CFW-144 fail-fast) ==="
run_case "large-multipart" "large" "order_fixture order-mp-1 brand-1 video" export CFW_RENDER_UPLOAD_MODE=multipart
if [[ "$(calls_count complete_render_order)" -eq 0 ]]; then
  pass "multipart: no complete_render_order (upload refused, nothing partial minted)"
else
  fail "multipart: complete" "expected 0 complete calls"
fi
if [[ "$(calls_count block_render_order)" -ge 1 ]]; then
  pass "multipart: order blocked with a reason (no silent fallback to presign)"
else
  fail "multipart: block" "expected block_render_order"
fi
if [[ -f "$CASE_MOCKSTATE/uploads.jsonl" ]] && grep -q '"via": "presign"' "$CASE_MOCKSTATE/uploads.jsonl"; then
  fail "multipart: fallback" "a presign upload happened in multipart-only mode"
else
  pass "multipart: no presign fallback"
fi

echo "=== Case 3: gate-fail path ==="
run_case "gate-fail" "gate-fail" "order_fixture order-gatefail-1 brand-1 video" true
if [[ "$(calls_count block_render_order)" -ge 1 ]]; then pass "gate-fail: block_render_order called"; else fail "gate-fail: block" "no block_render_order call"; fi
if [[ -d "$CASE_SCRATCH/test-brand/order-gatefail-1" ]]; then
  pass "gate-fail: scratch retained"
else
  fail "gate-fail: scratch retained" "scratch dir missing (should be kept for the 48h janitor)"
fi
if grep -q "order-gatefail-1.*block" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "gate-fail: journal row outcome=block"
else
  fail "gate-fail: journal row" "no block journal row found"
fi

echo "=== Case 3b: owner computer (byoa) — a blocked render keeps nothing in outputs ==="
c3b_home="$(mktemp -d)/CFW Render"
run_case "byoa-gate-fail" "gate-fail" "order_fixture order-gatefail-2 brand-1 video" \
  owner_layout "$c3b_home"
if [[ "$(calls_count block_render_order)" -ge 1 && -z "$(find "$c3b_home/outputs" -type f 2>/dev/null)" ]]; then
  pass "byoa-gate-fail: blocked, and outputs/ holds no file"
else
  fail "byoa-gate-fail: outputs" "files: $(find "$c3b_home/outputs" -type f 2>/dev/null | tr '\n' ' ')"
fi

echo "=== Case 4: watchdog timeout ==="
CASE_TIMEOUT_VIDEO=3 run_case "watchdog" "watchdog" "order_fixture order-watchdog-1 brand-1 video" true
if [[ "$(calls_count block_render_order)" -ge 1 ]] && grep -q "time budget" "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null; then
  pass "watchdog: block_render_order called with time-budget reason"
else
  fail "watchdog: block reason" "expected a block_render_order call mentioning 'time budget'"
fi
if grep -q "order-watchdog-1.*timeout" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "watchdog: journal row outcome=timeout"
else
  fail "watchdog: journal row" "no timeout journal row found"
fi
# [CFW-286] The watchdog kill must reach the WHOLE process group, not just the
# subshell — a straggler the Director backgrounded must not survive a
# watchdog-triggered block any more than a clean exit does.
watchdog_bg_pidfile="$CASE_SCRATCH/test-brand/order-watchdog-1/watchdog-bg.pid"
if [[ -f "$watchdog_bg_pidfile" ]]; then
  watchdog_bg_pid="$(cat "$watchdog_bg_pidfile" 2>/dev/null)"
  if [[ -n "$watchdog_bg_pid" ]] && ! kill -0 "$watchdog_bg_pid" 2>/dev/null; then
    pass "watchdog: backgrounded straggler reaped (group-kill on the watchdog path)"
  else
    fail "watchdog: straggler reap" "pid $watchdog_bg_pid is still alive after the tick"
  fi
else
  fail "watchdog: straggler reap" "watchdog-bg.pid not found — fake-director.sh didn't record it"
fi

echo "=== Case 4a: orphaned background — grace window absorbs a near-miss (CFW-286) ==="
# A background step that finishes WELL inside CFW_RENDER_ORPHAN_GRACE_SECS,
# after the Director itself has already exited 0 — the grace-poll must catch
# it and still land outcome=complete, not a false orphaned/crashed.
run_case "orphan-just-in-time" "orphan-just-in-time" "order_fixture order-orphan-jit-1 brand-1 video" \
  export CFW_RENDER_ORPHAN_GRACE_SECS=3 FAKE_DIRECTOR_ORPHAN_SLEEP=1
if grep -q "order-orphan-jit-1.*complete" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "orphan-just-in-time: journal row outcome=complete"
else
  fail "orphan-just-in-time: journal row" "no complete journal row found — grace window failed to absorb the near-miss"
fi
if [[ "$(calls_count complete_render_order)" == "1" ]]; then
  pass "orphan-just-in-time: complete_render_order called exactly once"
else
  fail "orphan-just-in-time: complete call" "expected 1 complete_render_order, got $(calls_count complete_render_order)"
fi
if [[ ! -d "$CASE_SCRATCH/test-brand/order-orphan-jit-1" ]]; then
  pass "orphan-just-in-time: scratch wiped"
else
  fail "orphan-just-in-time: scratch" "scratch dir still present after a complete outcome"
fi

echo "=== Case 4b: orphaned background — past the grace window (CFW-286, the bug itself) ==="
# A background step that would finish PAST the grace window — the exact
# "Director ends its turn with background work still running" sequence.
# Must land outcome=orphaned (never crashed), block_render_order with the
# orphaned-specific reason, the process group reaped, and NO
# complete_render_order racing in after the block.
run_case "orphan-late" "orphan-late" "order_fixture order-orphan-late-1 brand-1 video" \
  export CFW_RENDER_ORPHAN_GRACE_SECS=2 FAKE_DIRECTOR_ORPHAN_SLEEP=15
if grep -q "order-orphan-late-1.*orphaned" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "orphan-late: journal row outcome=orphaned"
else
  fail "orphan-late: journal row" "no orphaned journal row found (got: $(grep 'order-orphan-late-1' "$CASE_STATE/journal.tsv" 2>/dev/null))"
fi
if [[ "$(calls_count block_render_order)" -ge 1 ]] && grep -q "background step was still running" "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null; then
  pass "orphan-late: block_render_order called with the orphaned-specific reason"
else
  fail "orphan-late: block reason" "expected a block_render_order call mentioning 'background step was still running'"
fi
if [[ "$(calls_count complete_render_order)" == "0" ]]; then
  pass "orphan-late: no complete_render_order landed after the block (straggler didn't race the drainer's decision)"
else
  fail "orphan-late: stale complete" "a complete_render_order call landed — the reaped background process raced the block"
fi
orphan_bg_pidfile="$CASE_SCRATCH/test-brand/order-orphan-late-1/orphan-bg.pid"
if [[ -f "$orphan_bg_pidfile" ]]; then
  orphan_bg_pid="$(cat "$orphan_bg_pidfile" 2>/dev/null)"
  if [[ -n "$orphan_bg_pid" ]] && ! kill -0 "$orphan_bg_pid" 2>/dev/null; then
    pass "orphan-late: backgrounded straggler reaped, no longer alive"
  else
    fail "orphan-late: straggler reap" "pid $orphan_bg_pid is still alive after the tick"
  fi
else
  fail "orphan-late: straggler reap" "orphan-bg.pid not found — fake-director.sh didn't record it"
fi

echo "=== Case 4d: heartbeat + renderer identity (CFW-146) ==="
# A 2-second pulse against an ~8-second Director → at least 2 heartbeats, each
# carrying the renderer kind and no pct, and NONE after the order is terminal.
run_case "heartbeat" "heartbeat" "order_fixture order-hb-1 brand-1 video" export CFW_RENDER_HEARTBEAT_SECS=2
hb_check="$(python3 -c '
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
hb = [c for c in calls if c.get("tool") == "append_render_event" and c.get("args", {}).get("kind") == "heartbeat"]
claim = next((c for c in calls if c.get("tool") == "claim_render_order"), None)
problems = []
if len(hb) < 2:
    problems.append("heartbeats=%d (expected >=2)" % len(hb))
if any(c["args"].get("pct") is not None for c in hb):
    problems.append("a heartbeat carried a pct")
kinds = {c["args"].get("stage") for c in hb}
if kinds and not kinds <= {"mac", "box", "byo", "fleet"}:
    problems.append("bad renderer kinds on heartbeats: %r" % kinds)
if any(not c.get("ok") for c in hb):
    problems.append("a heartbeat was rejected by the server")
if not claim or not isinstance(claim["args"].get("renderer"), dict):
    problems.append("claim carried no renderer identity")
elif claim["args"]["renderer"].get("kind") not in ("mac", "box", "byo", "fleet"):
    problems.append("claim renderer kind %r" % claim["args"]["renderer"].get("kind"))
# nothing may follow the terminal call
seen_terminal = False
late = 0
for c in calls:
    if c.get("tool") in ("complete_render_order", "block_render_order"):
        seen_terminal = True
        continue
    if seen_terminal and c.get("tool") == "append_render_event":
        late += 1
if late:
    problems.append("%d event(s) after the order went terminal" % late)
print("OK" if not problems else "BAD " + "; ".join(problems))
' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null || echo "BAD could not read calls.jsonl")"
if [[ "$hb_check" == "OK" ]]; then
  pass "heartbeat: >=2 pulses with renderer kind, no pct, none after terminal; claim carries the renderer"
else
  fail "heartbeat" "$hb_check"
fi
if [[ "$(calls_count complete_render_order)" == "1" ]]; then
  pass "heartbeat: the render still completed normally"
else
  fail "heartbeat: complete" "expected 1 complete_render_order, got $(calls_count complete_render_order)"
fi
# No process-table lookups here: the suite never matches commands by name, and
# the runner sandbox refuses setuid tools such as ps. Cleanup goes through
# stop_test_tree / test/stop-owned-tree.py (libproc via ctypes) only.

echo '=== Case 4e: block carries `needs` (CFW-146) ==='
run_case "needs-ingredient" "needs-ingredient" "order_fixture order-needs-1 brand-1 video" true
needs_check="$(python3 -c '
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
blocks = [c for c in calls if c.get("tool") == "block_render_order"]
if not blocks:
    print("BAD no block_render_order call"); raise SystemExit
a = blocks[-1]["args"]
if a.get("needs") != "ingredient":
    print("BAD needs=%r" % a.get("needs")); raise SystemExit
if not blocks[-1].get("ok"):
    print("BAD block rejected by the server"); raise SystemExit
print("OK")
' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null || echo "BAD could not read calls.jsonl")"
if [[ "$needs_check" == "OK" ]]; then
  pass "needs: block_render_order carries needs=ingredient (card offers an upload)"
else
  fail "needs" "$needs_check"
fi
if grep -q "order-needs-1.*block" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "needs: journal row outcome=block"
else
  fail "needs: journal row" "no block journal row found"
fi

echo "=== Case 5: empty queue ==="
run_case "empty-queue" "happy" empty_queue true
if [[ "$CASE_DRAINER_EXIT" == "0" ]]; then pass "empty-queue: drainer exits 0"; else fail "empty-queue: exit" "expected 0, got $CASE_DRAINER_EXIT"; fi
if [[ "$(calls_count claim_render_order)" -ge 1 ]]; then pass "empty-queue: claim was attempted"; else fail "empty-queue: claim" "expected at least one claim attempt"; fi
if [[ "$(calls_count block_render_order)" == "0" && "$(calls_count complete_render_order)" == "0" ]]; then
  pass "empty-queue: no spawn (no complete/block calls)"
else
  fail "empty-queue: no spawn" "unexpected complete/block calls on an empty queue"
fi

echo "=== Case 6: tick lock exclusion ==="
lock_state="$(mktemp -d)"
mkdir -p "$lock_state/tick.lock"
printf 'pid=%s\nts=%s\n' "$$" "$(date +%s)" > "$lock_state/tick.lock/info"
lock_seed="$(mktemp)"; order_fixture order-lock-1 brand-1 video > "$lock_seed"
lock_mock_state="$(mktemp -d)"
lock_port=$((MOCK_PORT_BASE + 80))
lock_pid="$(start_mock "$lock_seed" "$lock_mock_state" "$lock_port")"
lock_scratch_dir="$(mktemp -d)"
lock_skills_dir="$(mktemp -d)"
(
  export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
  export CFW_API_BASE="http://127.0.0.1:$lock_port"
  export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
  export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
  export CFW_RENDER_STATE_DIR="$lock_state"
  export CFW_RENDER_LOG_DIR="$lock_state" CFW_RENDER_KEEP_OUTPUTS=0
  export CFW_RENDER_SCRATCH="$lock_scratch_dir"
  export CFW_RENDER_SKILLS_DIR="$lock_skills_dir"
  export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
  "$REPO_DIR/bin/cfw-render.sh" --once
)
lock_exit=$?
kill "$lock_pid" 2>/dev/null; wait "$lock_pid" 2>/dev/null
if [[ "$lock_exit" == "0" ]]; then pass "tick-lock: second invocation exits 0"; else fail "tick-lock: exit" "expected 0, got $lock_exit"; fi
lock_calls="$(wc -l < "$lock_mock_state/calls.jsonl" 2>/dev/null | tr -d ' ')"
[[ -z "$lock_calls" ]] && lock_calls=0
if [[ "$lock_calls" == "0" ]]; then pass "tick-lock: no claim while lock held"; else fail "tick-lock: claim count" "expected 0 tool calls, got $lock_calls"; fi

echo "=== Case 8: default settings file is ~/.cfw-render/cfw-render.env (legacy ~/ecosystem/vault only as fallback); no ~/.gsai/secrets (CFW-289) ==="
# Regression for CFW-289: bin/cfw-render-lib.sh's three credential-path
# defaults used to point at the retired ~/.gsai/secrets vault. Each sub-case
# runs under a throwaway $HOME so the assertions don't depend on (or touch)
# this machine's real vault state, and the --dry sub-case talks to a mock
# server — never a live CFW_API_BASE.
c289_home="$(mktemp -d)"

# 1. cr_load_config: default CFW_RENDER_ENV path, no required vars set — the
#    "missing required" error interpolates the path it checked.
c289_out="$(
  env -i HOME="$c289_home" PATH="$PATH" bash -c '
    set -u
    source "'"$REPO_DIR"'/bin/cfw-render-lib.sh"
    cr_load_config
  ' 2>&1
)"
if echo "$c289_out" | grep -qF "$c289_home/.cfw-render/cfw-render.env" && ! echo "$c289_out" | grep -q 'ecosystem/vault\|\.gsai'; then
  pass "cr_load_config: default env path is ~/.cfw-render/cfw-render.env (no ecosystem/vault, no .gsai)"
else
  fail "cr_load_config: default env path" "expected ~/.cfw-render/cfw-render.env with no ecosystem/vault or .gsai mention, got: $c289_out"
fi

# 1b. An install from before the folder layout change keeps its settings file
#     at ~/ecosystem/vault — still read when the new file is absent.
c8_legacy_home="$(mktemp -d)"
mkdir -p "$c8_legacy_home/ecosystem/vault"
printf 'CFW_API_BASE=http://legacy.example\nCFW_RENDER_WORKER_KEY=cfw_render_legacykey\n' > "$c8_legacy_home/ecosystem/vault/cfw-render.env"
c8_legacy_out="$(
  env -i HOME="$c8_legacy_home" PATH="$PATH" bash -c '
    set -u
    source "'"$REPO_DIR"'/bin/cfw-render-lib.sh"
    CFW_WORKER_ID=test-worker cr_load_config >/dev/null 2>&1 || { echo LOAD_FAILED; exit 0; }
    echo "base=$CFW_API_BASE"
  ' 2>&1
)"
if [[ "$c8_legacy_out" == "base=http://legacy.example" ]]; then
  pass "cr_load_config: legacy ~/ecosystem/vault/cfw-render.env still loads when the new file is absent"
else
  fail "cr_load_config: legacy env fallback" "got: $c8_legacy_out"
fi

# 1c. When both exist, the new location wins.
mkdir -p "$c8_legacy_home/.cfw-render"
printf 'CFW_API_BASE=http://new.example\nCFW_RENDER_WORKER_KEY=cfw_render_newkey\n' > "$c8_legacy_home/.cfw-render/cfw-render.env"
c8_both_out="$(
  env -i HOME="$c8_legacy_home" PATH="$PATH" bash -c '
    set -u
    source "'"$REPO_DIR"'/bin/cfw-render-lib.sh"
    CFW_WORKER_ID=test-worker cr_load_config >/dev/null 2>&1 || { echo LOAD_FAILED; exit 0; }
    echo "base=$CFW_API_BASE"
  ' 2>&1
)"
if [[ "$c8_both_out" == "base=http://new.example" ]]; then
  pass "cr_load_config: ~/.cfw-render/cfw-render.env wins over the legacy file"
else
  fail "cr_load_config: new env file precedence" "got: $c8_both_out"
fi
rm -rf "$c8_legacy_home"

# 3. cr_load_config's ollama-keys default, surfaced via `cfw-render.sh --dry`'s
#    health table (against a mock server, not a live CFW_API_BASE).
c289_seed="$(mktemp)"; empty_queue > "$c289_seed"
c289_state="$(mktemp -d)"
c289_port=$((MOCK_PORT_BASE + 80))
c289_pid="$(start_mock "$c289_seed" "$c289_state" "$c289_port")"
c289_dry_out="$(
  env -i HOME="$c289_home" PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH" \
    CFW_API_BASE="http://127.0.0.1:$c289_port" \
    CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000" \
    CFW_RENDER_STATE_DIR="$c289_home/cr-state" \
    CFW_RENDER_LOG_DIR="$c289_home/cr-state" \
    CFW_RENDER_SCRATCH="$c289_home/cr-scratch" \
    CFW_RENDER_SKILLS_DIR="$c289_home/skills" \
    "$REPO_DIR/bin/cfw-render.sh" --dry 2>&1
)"
kill "$c289_pid" 2>/dev/null; wait "$c289_pid" 2>/dev/null
if echo "$c289_dry_out" | grep -q "ecosystem/vault/ollama-keys.env" && ! echo "$c289_dry_out" | grep -q '\.gsai'; then
  pass "cfw-render.sh --dry: default ollama-keys path is ~/ecosystem/vault, not ~/.gsai/secrets"
else
  fail "cfw-render.sh --dry: default ollama-keys path" "expected ecosystem/vault/ollama-keys.env with no .gsai mention, got: $c289_dry_out"
fi

echo "=== Case 9: static guard — no live reference to the retired ~/.gsai/secrets vault ==="
# Cheap grep gate so a future doc edit can't copy the old prose back in.
# backlog/ is excluded on purpose — those are dated historical task records
# from when ~/.gsai/secrets was the live convention (see design notes).
c289_grep_raw="$(grep -rn '\.gsai/secrets' "$REPO_DIR/bin" "$REPO_DIR/lib" "$REPO_DIR/config" "$REPO_DIR"/install/*.md "$REPO_DIR/README.md" "$REPO_DIR/docs" 2>/dev/null)"
# README's "Ollama keys vs zai.env" note intentionally keeps ONE historical
# mention — the task text's original wrong *file*, not the retired vault
# *directory* (see the design doc for CFW-289). Exclude that single known line.
c289_grep_out="$(printf '%s\n' "$c289_grep_raw" | grep -v "README.md:.*task text originally said")"
c289_grep_out="$(printf '%s\n' "$c289_grep_out" | sed '/^$/d')"
if [[ -z "$c289_grep_out" ]]; then
  pass "static guard: no live bin/lib/config/docs reference to ~/.gsai/secrets"
else
  fail "static guard: retired vault path" "found live references: $c289_grep_out"
fi

echo "=== Case 9b: static guard — the guides installed on an owner's computer never point at the maintainer's ~/ecosystem/vault ==="
# install/*.md are maintainer/fleet docs and may name the legacy location to
# explain the fallback; AGENTS.md + CLAUDE.md ship into every owner install.
c9b_out="$(grep -n 'ecosystem/vault' "$REPO_DIR/AGENTS.md" "$REPO_DIR/CLAUDE.md" 2>/dev/null)"
if [[ -z "$c9b_out" ]]; then
  pass "static guard: AGENTS.md and CLAUDE.md mention no ecosystem/vault path"
else
  fail "static guard: ecosystem/vault in a public guide" "$c9b_out"
fi

echo "=== Case 10: sync-skills.py rewrites host-path sub-skill resolvers to .hub/ (CFW-312) ==="
c312_out="$(mktemp -d)"
c312_sync_log="$(
  CFW_SKILLS_SRC="$TEST_DIR/fixtures/skills-src" "$REPO_DIR/scripts/sync-skills.sh" \
    --recipes "$TEST_DIR/fixtures/fixture-recipes.json" --out-dir "$c312_out" --skip-manifest 2>&1
)"
c312_sync_rc=$?
if [[ "$c312_sync_rc" == "0" ]]; then
  pass "sync-skills.sh: fixture sync + portability gate exit 0"
else
  fail "sync-skills.sh: fixture sync" "expected exit 0, got $c312_sync_rc — log: $c312_sync_log"
fi

c312_top_skill_dir="$(grep '^SKILL_DIR=' "$c312_out/p-fixture-recipe/SKILL.md" 2>/dev/null)"
if [[ "$c312_top_skill_dir" == 'SKILL_DIR="${CFW_RENDER_SKILLS_DIR:?CFW_RENDER_SKILLS_DIR not set}/p-fixture-recipe"' ]]; then
  pass "sync-skills.py: top-level recipe's own-dir line anchors on CFW_RENDER_SKILLS_DIR"
else
  fail "sync-skills.py: own-dir rewrite" "got: $c312_top_skill_dir"
fi

c312_sub_dir="$(grep '^FIXTURE_DEP_DIR=' "$c312_out/p-fixture-recipe/SKILL.md" 2>/dev/null)"
if [[ "$c312_sub_dir" == 'FIXTURE_DEP_DIR="$SKILL_DIR/.hub/c-fixture-dep"' ]]; then
  pass "sync-skills.py: sub-skill-dir line resolves against bundled .hub/, not a host find"
else
  fail "sync-skills.py: sub-skill-dir rewrite" "got: $c312_sub_dir"
fi

if grep -q '\[ -n "\$FIXTURE_DEP_DIR" \]' "$c312_out/p-fixture-recipe/SKILL.md" 2>/dev/null; then
  fail "sync-skills.py: dead fallback" "the now-dead '[ -n ... ] || ...' fallback line should have been dropped"
else
  pass "sync-skills.py: dead fallback line dropped (rewritten assignment is unconditional)"
fi

c312_nested_skill_dir="$(grep '^SKILL_DIR=' "$c312_out/p-fixture-recipe/.hub/c-fixture-dep/SKILL.md" 2>/dev/null)"
if [[ "$c312_nested_skill_dir" == 'SKILL_DIR="${CFW_RENDER_SKILLS_DIR:?CFW_RENDER_SKILLS_DIR not set}/p-fixture-recipe/.hub/c-fixture-dep"' ]]; then
  pass "sync-skills.py: vendored dep's own-dir line resolves to its actual on-disk .hub/ location"
else
  fail "sync-skills.py: vendored dep own-dir rewrite" "got: $c312_nested_skill_dir"
fi

if "$REPO_DIR/scripts/check-skills-portability.sh" --skills-dir "$c312_out" >/dev/null 2>&1; then
  pass "check-skills-portability.sh: PASS on the rewritten fixture bundle"
else
  fail "check-skills-portability.sh: fixture bundle" "expected exit 0 after rewrite"
fi

if "$REPO_DIR/scripts/check-skills-portability.sh" --skills-dir "$c312_out" c-fixture-clean >/dev/null 2>&1; then
  pass "check-skills-portability.sh: clean recipe (no dependsOn, no resolver) doesn't false-positive"
else
  fail "check-skills-portability.sh: clean recipe" "expected exit 0 for c-fixture-clean"
fi
rm -rf "$c312_out"

echo "=== Case 11: static guard — bundled skills resolve sub-skills from .hub/, not host paths (CFW-312) ==="
if "$REPO_DIR/scripts/check-skills-portability.sh" >/dev/null 2>&1; then
  pass "static guard: committed skills/ bundle has no host-path sub-skill resolver"
else
  c312_real_out="$("$REPO_DIR/scripts/check-skills-portability.sh" 2>&1)"
  fail "static guard: host-path resolver in committed bundle" "$c312_real_out"
fi

echo "=== Case 12: static guard — no worker-vault HeyGen credential in bin/lib/config (CFW-313) ==="
if "$REPO_DIR/scripts/check-no-worker-heygen-credential.sh" >/dev/null 2>&1; then
  pass "static guard: no worker-vault HeyGen credential reference in bin/lib/config"
else
  c313_guard_out="$("$REPO_DIR/scripts/check-no-worker-heygen-credential.sh" 2>&1)"
  fail "static guard: worker-vault HeyGen credential reference found" "$c313_guard_out"
fi

echo "=== Case 13: HeyGen credential present + unexpired — exported into the Director's env, never HEYGEN_API_KEY (CFW-313) ==="
run_case "heygen-present" "heygen-cred" \
  'order_fixture_heygen order-heygen-ok-1 brand-1 video {"mode":"oauth","accessToken":"test-heygen-oauth-token-abc123","expiresAt":"2099-01-01T00:00:00Z","creditPool":"plan_credits"}' \
  true
if [[ "$(calls_count block_render_order)" == "1" ]]; then
  pass "heygen-present: Director spawned and ran (it blocked itself — this fixture is a probe, not a real render)"
else
  fail "heygen-present: director spawn" "expected exactly 1 block_render_order (from the Director's own probe block), got $(calls_count block_render_order)"
fi
heygen_env_file="$CASE_SCRATCH/test-brand/order-heygen-ok-1/heygen-env.txt"
if [[ -f "$heygen_env_file" ]]; then
  pass "heygen-present: Director's env was captured"
else
  fail "heygen-present: env capture" "heygen-env.txt not found at $heygen_env_file"
fi
heygen_env_check="$(python3 -c '
import sys
vals = {}
try:
    for line in open(sys.argv[1] if len(sys.argv) > 1 else "/dev/null"):
        if "=" in line:
            k, v = line.rstrip("\n").split("=", 1)
            vals[k] = v
except FileNotFoundError:
    print("BAD file missing"); raise SystemExit
problems = []
if vals.get("HEYGEN_OAUTH_TOKEN") != "test-heygen-oauth-token-abc123":
    problems.append("HEYGEN_OAUTH_TOKEN=%r" % vals.get("HEYGEN_OAUTH_TOKEN"))
if vals.get("HEYGEN_CREDIT_POOL") != "plan_credits":
    problems.append("HEYGEN_CREDIT_POOL=%r" % vals.get("HEYGEN_CREDIT_POOL"))
if vals.get("HEYGEN_TOKEN_EXPIRES_AT") != "2099-01-01T00:00:00Z":
    problems.append("HEYGEN_TOKEN_EXPIRES_AT=%r" % vals.get("HEYGEN_TOKEN_EXPIRES_AT"))
if vals.get("HEYGEN_API_KEY"):
    problems.append("HEYGEN_API_KEY was set (%r) — must never be, this is an OAuth credential" % vals.get("HEYGEN_API_KEY"))
print("OK" if not problems else "BAD " + "; ".join(problems))
' "$heygen_env_file" 2>/dev/null || echo "BAD could not read $heygen_env_file")"
if [[ "$heygen_env_check" == "OK" ]]; then
  pass "heygen-present: HEYGEN_OAUTH_TOKEN/HEYGEN_CREDIT_POOL/HEYGEN_TOKEN_EXPIRES_AT landed correctly, HEYGEN_API_KEY never set"
else
  fail "heygen-present: env values" "$heygen_env_check"
fi

echo "=== Case 13b: HeyGen credential absent — blocked with needs=decision, Director never spawned (CFW-313) ==="
run_case "heygen-absent" "heygen-cred" "order_fixture_heygen order-heygen-absent-1 brand-1 video" true
if [[ "$(calls_count append_render_event)" == "0" ]]; then
  pass "heygen-absent: no append_render_event — the Director was never spawned"
else
  fail "heygen-absent: no spawn" "expected 0 append_render_event calls, got $(calls_count append_render_event)"
fi
if [[ "$(calls_count complete_render_order)" == "0" ]]; then
  pass "heygen-absent: no complete_render_order"
else
  fail "heygen-absent: complete" "expected 0 complete_render_order calls"
fi
heygen_absent_check="$(python3 -c '
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
blocks = [c for c in calls if c.get("tool") == "block_render_order"]
if len(blocks) != 1:
    print("BAD block_render_order called %d times (expected 1)" % len(blocks)); raise SystemExit
a = blocks[0]["args"]
problems = []
if a.get("needs") != "decision":
    problems.append("needs=%r" % a.get("needs"))
if "connect" not in (a.get("reason") or "").lower():
    problems.append("reason does not mention connecting the account: %r" % a.get("reason"))
if not blocks[0].get("ok"):
    problems.append("block rejected by the server")
print("OK" if not problems else "BAD " + "; ".join(problems))
' "$CASE_MOCKSTATE/calls.jsonl" 2>/dev/null || echo "BAD could not read calls.jsonl")"
if [[ "$heygen_absent_check" == "OK" ]]; then
  pass "heygen-absent: block_render_order carries needs=decision + an owner-actionable reason"
else
  fail "heygen-absent" "$heygen_absent_check"
fi
if grep -q "order-heygen-absent-1.*block" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "heygen-absent: journal row outcome=blocked"
else
  fail "heygen-absent: journal row" "no blocked journal row found"
fi

echo "=== Case 13c: HeyGen credential present but expired — treated identically to absent (CFW-313) ==="
run_case "heygen-expired" "heygen-cred" \
  'order_fixture_heygen order-heygen-expired-1 brand-1 video {"mode":"oauth","accessToken":"test-heygen-oauth-token-expired","expiresAt":"2000-01-01T00:00:00Z","creditPool":"plan_credits"}' \
  true
if [[ "$(calls_count append_render_event)" == "0" ]]; then
  pass "heygen-expired: no append_render_event — the Director was never spawned"
else
  fail "heygen-expired: no spawn" "expected 0 append_render_event calls, got $(calls_count append_render_event)"
fi
if grep -q "order-heygen-expired-1.*block" "$CASE_STATE/journal.tsv" 2>/dev/null; then
  pass "heygen-expired: journal row outcome=blocked (expired token treated as absent)"
else
  fail "heygen-expired: journal row" "no blocked journal row found"
fi

echo "=== Case 14: sync-skills.py strips brand-overrides host paths + redacts bare host paths + stamps index.json sourceSha (CFW-318) ==="
# Copy the fixture source tree OUTSIDE this repo's working tree first — a
# `git -C <dir> rev-parse HEAD` resolves upward to the nearest enclosing
# repo, so pointing CFW_SKILLS_SRC straight at test/fixtures/skills-src (a
# subdir OF this repo) would silently return cfw-render's own HEAD instead
# of exercising git_head_sha()'s non-git soft-fail path.
c318_src_copy="$(mktemp -d)"
cp -R "$TEST_DIR/fixtures/skills-src/." "$c318_src_copy/"
c318_out="$(mktemp -d)"
c318_sync_log="$(
  CFW_SKILLS_SRC="$c318_src_copy" "$REPO_DIR/scripts/sync-skills.sh" \
    --recipes "$TEST_DIR/fixtures/fixture-recipes.json" --out-dir "$c318_out" --skip-manifest 2>&1
)"
c318_sync_rc=$?
if [[ "$c318_sync_rc" == "0" ]]; then
  pass "sync-skills.sh: fixture sync + check-no-host-paths gate exit 0 (CFW-318)"
else
  fail "sync-skills.sh: fixture sync (CFW-318)" "expected exit 0, got $c318_sync_rc — log: $c318_sync_log"
fi

c318_brand_json="$c318_out/p-fixture-recipe/brand-overrides/fixture-brand/brand.json"
c318_outro_path="$(python3 -c "import json; print(json.load(open('$c318_brand_json'))['outro']['path'])" 2>/dev/null)"
if [[ "$c318_outro_path" == "None" ]]; then
  pass "sync-skills.py: brand-overrides outro.path nulled (CFW-318)"
else
  fail "sync-skills.py: outro.path strip" "got: $c318_outro_path"
fi

c318_outro_relative="$(python3 -c "import json; print(json.load(open('$c318_brand_json'))['outro']['relative'])" 2>/dev/null)"
if [[ "$c318_outro_relative" == "fixture-assets/outro.png" ]]; then
  pass "sync-skills.py: outro.relative survives untouched (CFW-318)"
else
  fail "sync-skills.py: outro.relative" "got: $c318_outro_relative"
fi

if python3 -c "import json,sys; d=json.load(open('$c318_brand_json')); sys.exit(0 if 'hero_portrait' not in d else 1)"; then
  pass "sync-skills.py: hero_portrait key dropped entirely (CFW-318)"
else
  fail "sync-skills.py: hero_portrait" "key still present in $c318_brand_json"
fi

c318_doc="$c318_out/p-fixture-recipe/docs/HOST-PATH-NOTE.md"
if grep -q '/Users/<redacted>/some/scratch/path/mirror' "$c318_doc" 2>/dev/null; then
  pass "sync-skills.py: bare host-path string redacted in a doc file (CFW-318)"
else
  fail "sync-skills.py: generic redaction" "redacted placeholder not found in $c318_doc"
fi

if grep -q 'testuser' "$c318_doc" 2>/dev/null && ! grep -q '/Users/testuser' "$c318_doc" 2>/dev/null; then
  pass "sync-skills.py: negative case — bare 'testuser' with no /Users/ prefix left untouched (CFW-318)"
else
  fail "sync-skills.py: negative case" "unexpected content in $c318_doc"
fi

if "$REPO_DIR/scripts/check-no-host-paths.sh" --skills-dir "$c318_out" >/dev/null 2>&1; then
  pass "check-no-host-paths.sh: PASS on the rewritten fixture bundle (CFW-318)"
else
  fail "check-no-host-paths.sh: fixture bundle" "expected exit 0 after rewrite"
fi

c318_sha="$(python3 -c "import json; print(json.load(open('$c318_out/index.json'))['sourceSha'])" 2>/dev/null)"
if [[ "$c318_sha" == "None" ]]; then
  pass "sync-skills.py: index.json sourceSha stays null for a non-git fixture source (soft-fail path, CFW-318)"
else
  fail "sync-skills.py: sourceSha soft-fail" "expected None, got: $c318_sha"
fi
rm -rf "$c318_out" "$c318_src_copy"

echo "=== Case 14a: check-no-host-paths.sh red/green — FAILs on a deliberately unrewritten host path (CFW-318) ==="
c318_dirty_base="$(mktemp -d)"
mkdir -p "$c318_dirty_base/p-dirty-recipe"
printf 'leftover path: /Users/testuser/leftover/path\n' > "$c318_dirty_base/p-dirty-recipe/NOTE.md"
if "$REPO_DIR/scripts/check-no-host-paths.sh" --skills-dir "$c318_dirty_base" >/dev/null 2>&1; then
  fail "check-no-host-paths.sh: red case" "expected exit 1 on a deliberately unrewritten fixture"
else
  pass "check-no-host-paths.sh: FAILs on a deliberately unrewritten host path (red/green proof, CFW-318)"
fi
rm -rf "$c318_dirty_base"

echo "=== Case 14b: static guard — no bare host path anywhere in the committed skills/ bundle (CFW-318) ==="
if "$REPO_DIR/scripts/check-no-host-paths.sh" >/dev/null 2>&1; then
  pass "static guard: committed skills/ bundle has no bare host path"
else
  c318_real_out="$("$REPO_DIR/scripts/check-no-host-paths.sh" 2>&1)"
  fail "static guard: bare host path found in committed bundle" "$c318_real_out"
fi

echo "=== Case 14c: index.json sourceSha stamped from a real git source repo (CFW-318) ==="
c318_git_src="$(mktemp -d)"
mkdir -p "$c318_git_src/p-git-fixture"
cat > "$c318_git_src/p-git-fixture/SKILL.md" <<'EOF'
---
name: p-git-fixture
kind: pipeline
visibility: catalog
---

# p-git-fixture (CFW-318 test fixture — git sourceSha stamping)
EOF
(
  cd "$c318_git_src" &&
  git init -q &&
  git config user.email test@example.com &&
  git config user.name test &&
  git add -A &&
  git commit -q -m fixture
) >/dev/null 2>&1
c318_git_recipes="$(mktemp)"
python3 -c "import json; json.dump({'recipes': [{'name': 'p-git-fixture', 'version': '1.0.0', 'providers': []}]}, open('$c318_git_recipes', 'w'))"
c318_git_out="$(mktemp -d)"
CFW_SKILLS_SRC="$c318_git_src" "$REPO_DIR/scripts/sync-skills.sh" \
  --recipes "$c318_git_recipes" --out-dir "$c318_git_out" --skip-manifest >/dev/null 2>&1
c318_expected_sha="$(git -C "$c318_git_src" rev-parse HEAD)"
c318_got_sha="$(python3 -c "import json; print(json.load(open('$c318_git_out/index.json'))['sourceSha'])" 2>/dev/null)"
if [[ "$c318_got_sha" == "$c318_expected_sha" ]]; then
  pass "sync-skills.py: index.json sourceSha matches git rev-parse HEAD of the source repo (CFW-318)"
else
  fail "sync-skills.py: sourceSha from real git source" "expected $c318_expected_sha, got $c318_got_sha"
fi
rm -rf "$c318_git_src" "$c318_git_out" "$c318_git_recipes"

echo "=== Case P: toolchain preflight refuses to claim on a half-provisioned host ==="
# CFW-199 / CFW-188. hst had NO ImageMagick and was one `systemctl enable` from
# claiming production orders it could not finish. The drainer must now refuse.
pf_dir="$(mktemp -d)"; mkdir -p "$pf_dir/mockstate"
order_fixture order-preflight-1 brand-1 video > "$pf_dir/queue.json"
pf_port=$((MOCK_PORT_BASE + 95))
pf_pid="$(start_mock "$pf_dir/queue.json" "$pf_dir/mockstate" "$pf_port")"

# A PATH shim that hides exactly ONE required tool — ImageMagick — and passes
# everything else through unchanged. That is the shape of the CFW-188 box: fully
# provisioned except for the one binary the recipes need.
pf_shim="$(mktemp -d)"
pf_full_path="$REPO_DIR/bin:$FAKE_BIN:$PATH"
IFS=':' read -ra pf_path_dirs <<< "$pf_full_path"
for pf_d in "${pf_path_dirs[@]}"; do
  [[ -n "$pf_d" && -d "$pf_d" ]] || continue
  for pf_f in "$pf_d"/*; do
    [[ -f "$pf_f" || -L "$pf_f" ]] || continue
    [[ -x "$pf_f" ]] || continue
    pf_b="${pf_f##*/}"
    [[ "$pf_b" == "magick" || "$pf_b" == "convert" ]] && continue
    [[ -e "$pf_shim/$pf_b" ]] || ln -s "$pf_f" "$pf_shim/$pf_b" 2>/dev/null
  done
done

pf_out=""; pf_exit=0
pf_run() { # pf_run <PATH> — sets $pf_out and $pf_exit (NOT via command
           # substitution: that is a subshell and $pf_out would not survive)
  pf_out="$(
    export PATH="$1"
    export CFW_API_BASE="http://127.0.0.1:$pf_port"
    export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
    export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
    export CFW_RENDER_STATE_DIR="$pf_dir/cr-state"
    export CFW_RENDER_LOG_DIR="$pf_dir/cr-state" CFW_RENDER_KEEP_OUTPUTS=0
    export CFW_RENDER_SCRATCH="$pf_dir/cr-scratch"
    export CFW_RENDER_SKILLS_DIR="$pf_dir/skills"
    export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
    export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
    "$REPO_DIR/bin/cfw-render.sh" 2>&1
  )"
  pf_exit=$?
}

pf_run "$pf_shim"
if [[ "$pf_exit" != "0" ]]; then
  pass "preflight: a host missing ImageMagick exits non-zero"
else
  fail "preflight: exit code" "expected non-zero on a host without 'magick', got 0"
fi
if echo "$pf_out" | grep -q "magick"; then
  pass "preflight: names the missing tool"
else
  fail "preflight: message" "failure output does not name 'magick': $pf_out"
fi
if echo "$pf_out" | grep -qiE "brew install imagemagick|apt-get install -y imagemagick"; then
  pass "preflight: names how to install it"
else
  fail "preflight: install hint" "no install command in the failure output"
fi
# NB: `grep -c ... || echo 0` double-prints when the file exists but has no
# match (grep exits 1 having already printed "0") — the harness hit that before.
pf_claims=0
if [[ -f "$pf_dir/mockstate/calls.jsonl" ]]; then
  pf_claims="$(grep -c '"tool": "claim_render_order"' "$pf_dir/mockstate/calls.jsonl")" || pf_claims=0
fi
if [[ "$pf_claims" == "0" ]]; then
  pass "preflight: claimed NOTHING (the queued order is untouched)"
else
  fail "preflight: claimed work" "expected 0 claim_render_order calls, got $pf_claims"
fi

# Same host, full PATH restored: the drainer runs normally. Proves the gate is
# the missing tool, not the shim.
pf_run "$REPO_DIR/bin:$FAKE_BIN:$PATH"
pf_ok_exit="$pf_exit"
if [[ "$pf_ok_exit" == "0" ]]; then
  pass "preflight: a fully-provisioned host still runs"
else
  fail "preflight: false negative" "expected 0 on a complete toolchain, got $pf_ok_exit"
fi

kill "$pf_pid" 2>/dev/null; wait "$pf_pid" 2>/dev/null
rm -rf "$pf_shim"

# ===========================================================================
# CFW-291: resolved-binary worker PATH + headless claude probe + Linux
# coverage. None of the cases below need the mock server — these are pure
# bash-function and template-rendering checks (same "no live services" rule
# already governing this file).
# ===========================================================================

echo "=== Case Q1: cr_resolve_worker_path finds a nonstandard binary location ==="
q1_tmp="$(mktemp -d)"
mkdir -p "$q1_tmp/weird"
cp "$TEST_DIR/fake-claude.sh" "$q1_tmp/weird/claude"
chmod +x "$q1_tmp/weird/claude"
q1_out="$(
  export PATH="$q1_tmp/weird:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"
if [[ ":$q1_out:" == *":$q1_tmp/weird:"* ]]; then
  pass "cr_resolve_worker_path: resolves a nonstandard claude location (not the CFW-279 guessed list)"
else
  fail "cr_resolve_worker_path: nonstandard location" "expected $q1_tmp/weird in: $q1_out"
fi
rm -rf "$q1_tmp"

echo "=== Case Q2: cr_resolve_worker_path dedups + preserves the static fallback dirs ==="
q2_tmp="$(mktemp -d)"
mkdir -p "$q2_tmp/custom"
for q2_b in curl python3; do
  q2_real="$(command -v "$q2_b")"
  [[ -n "$q2_real" ]] && ln -s "$q2_real" "$q2_tmp/custom/$q2_b"
done
q2_out="$(
  export PATH="$q2_tmp/custom:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"
q2_count="$(printf '%s\n' "$q2_out" | tr ':' '\n' | grep -c "^$q2_tmp/custom\$")"
if [[ "$q2_count" == "1" ]]; then
  pass "cr_resolve_worker_path: two bins resolved into the same custom dir → that dir appears exactly once"
else
  fail "cr_resolve_worker_path: dedup" "expected 1 occurrence of $q2_tmp/custom, got $q2_count in: $q2_out"
fi
if [[ ":$q2_out:" == *":/usr/local/bin:"* && ":$q2_out:" == *":/opt/homebrew/bin:"* && ":$q2_out:" == *":/usr/bin:"* && ":$q2_out:" == *":/bin:"* ]]; then
  pass "cr_resolve_worker_path: static fallback dirs still present (CFW-279's Homebrew-case regression, now automated)"
else
  fail "cr_resolve_worker_path: fallback preserved" "missing a fallback dir in: $q2_out"
fi
rm -rf "$q2_tmp"

echo "=== Case Q3: cr_probe_claude_headless — the money test (catches what CFW-279's naive check could not) ==="
q3_tmp="$(mktemp -d)"
cp "$TEST_DIR/fake-claude-env-dependent.sh" "$q3_tmp/claude"
chmod +x "$q3_tmp/claude"
q3_naive_rc=1
(
  export PATH="$q3_tmp:$PATH"
  export FAKE_NVM_DIR=1
  command -v claude >/dev/null 2>&1 && claude --version >/dev/null 2>&1
)
q3_naive_rc=$?
if [[ "$q3_naive_rc" == "0" ]]; then
  pass "money test setup: naive 'command -v claude && claude --version' succeeds in the harness's own (rich) env — the exact CFW-279 gap"
else
  fail "money test setup" "naive command -v/claude --version unexpectedly failed in the harness's own env (rc=$q3_naive_rc)"
fi
(
  export PATH="$q3_tmp:$PATH"
  export FAKE_NVM_DIR=1
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_claude_headless "$q3_tmp:/usr/local/bin:/usr/bin:/bin"
) >/dev/null 2>&1
q3_probe_rc=$?
if [[ "$q3_probe_rc" != "0" ]]; then
  pass "money test: cr_probe_claude_headless FAILS under env -i (FAKE_NVM_DIR stripped) — caught at install time, not the first real tick"
else
  fail "money test: probe" "expected non-zero, cr_probe_claude_headless returned 0"
fi
rm -rf "$q3_tmp"

echo "=== Case Q4: cr_probe_claude_headless — success case, and empty-output-is-still-a-failure ==="
q4_tmp="$(mktemp -d)"
cp "$TEST_DIR/fake-claude.sh" "$q4_tmp/claude"
chmod +x "$q4_tmp/claude"
(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_claude_headless "$q4_tmp:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
) >/dev/null 2>&1
q4_rc=$?
if [[ "$q4_rc" == "0" ]]; then
  pass "cr_probe_claude_headless: succeeds against a claude that prints output and exits 0"
else
  fail "cr_probe_claude_headless: success case" "expected 0, got $q4_rc"
fi
rm -rf "$q4_tmp"

q4_empty="$(mktemp -d)"
cat > "$q4_empty/claude" <<'FAKECLAUDE'
#!/usr/bin/env bash
exit 0
FAKECLAUDE
chmod +x "$q4_empty/claude"
(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_claude_headless "$q4_empty:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
) >/dev/null 2>&1
q4_empty_rc=$?
if [[ "$q4_empty_rc" != "0" ]]; then
  pass "cr_probe_claude_headless: exit 0 but empty output is still a FAIL (mirrors cr_preflight's own claude --version rule)"
else
  fail "cr_probe_claude_headless: empty output" "expected non-zero, got 0"
fi
rm -rf "$q4_empty"

echo "=== Case Q5: cr_probe_claude_headless respects the stub-Director skip ==="
q5_empty_path="$(mktemp -d)"
(
  export PATH="$q5_empty_path"
  export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_claude_headless "$q5_empty_path"
) >/dev/null 2>&1
q5_rc=$?
if [[ "$q5_rc" == "0" ]]; then
  pass "cr_probe_claude_headless: SKIPs (returns 0) when CFW_RENDER_DIRECTOR_CMD is set, even with no claude anywhere on PATH"
else
  fail "cr_probe_claude_headless: stub skip" "expected 0 (SKIP), got $q5_rc"
fi
rm -rf "$q5_empty_path"

# ---------------------------------------------------------------------------
# _q291_relocate_bin <full_path> <custom_dir> <relocate_bin>
# Shared helper for Cases Q6/Q7 below — resolves <relocate_bin> on
# <full_path> and symlinks it alone into <custom_dir>. Unlike Case P (which
# must HIDE one tool while keeping everything else reachable, hence a full
# PATH mirror), Q6/Q7 only need to prove a relocated bin is found in a
# nonstandard location while every other tool keeps resolving normally — so
# the caller just puts <custom_dir> ahead of the real PATH; ordinary PATH
# precedence does the rest without mirroring every binary on the system
# (mirroring is what made this loop O(size of $PATH) and slow on boxes with
# a large ambient PATH).
# ---------------------------------------------------------------------------
_q291_relocate_bin() {
  local full_path="$1" custom="$2" relocate="$3" real
  real="$(PATH="$full_path" command -v "$relocate" 2>/dev/null)" || return 0
  ln -s "$real" "$custom/$relocate" 2>/dev/null
}

echo "=== Case Q6: install.sh renders the resolved WORKER_PATH into the macOS plist ==="
q6_browser_cache="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/Library/Caches/ms-playwright}"
q6_home="$(mktemp -d)"
q6_prefix="$(mktemp -d)"
q6_custom="$(mktemp -d)"
q6_env="$(mktemp)"
cat > "$q6_env" <<EOF
CFW_API_BASE=http://127.0.0.1:1
CFW_RENDER_WORKER_KEY=cfw_render_test0000000000000000
CFW_RENDER_STATE_DIR=$q6_home/cfw-render-state
CFW_RENDER_SCRATCH=$q6_home/cfw-render-scratch
EOF

_q291_relocate_bin "$REPO_DIR/bin:$FAKE_BIN:$PATH" "$q6_custom" ffmpeg
q6_test_path="$q6_custom:$REPO_DIR/bin:$FAKE_BIN:$PATH"

q6_expected_worker_path="$(
  export PATH="$q6_test_path"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"

(
  export HOME="$q6_home"
  export PATH="$q6_test_path"
  # PLAYWRIGHT_BROWSERS_PATH: cr_preflight_chromium's search is $HOME-relative
  # by default; since HOME is deliberately overridden to a scratch dir for
  # this hermetic test, point it back at the real cache so the unrelated
  # chromium/fonts preflight rows still PASS on a dev box that has Playwright
  # installed under the real $HOME — this test is about WORKER_PATH
  # rendering, not about re-testing chromium discovery.
  export PLAYWRIGHT_BROWSERS_PATH="$q6_browser_cache"
  # [M2-04] install.sh now bootout/bootstraps the LaunchAgent on re-run; never
  # load a real job from the test suite.
  export CFW_RENDER_INSTALL_NO_LAUNCHCTL=1
  "$REPO_DIR/install/install.sh" --mode byoa --prefix "$q6_prefix" --env-file "$q6_env" >"$q6_home/install.log" 2>&1
)

q6_plist="$q6_home/Library/LaunchAgents/com.cfw.render.plist"
if [[ -f "$q6_plist" ]]; then
  pass "install.sh: renders com.cfw.render.plist"
else
  fail "install.sh: plist written" "not found at $q6_plist — install.log tail: $(tail -20 "$q6_home/install.log" 2>/dev/null)"
fi

if [[ -f "$q6_plist" ]] && grep -qF '{{WORKER_PATH}}' "$q6_plist"; then
  fail "install.sh: leftover WORKER_PATH token" "plist still contains the literal {{WORKER_PATH}} placeholder"
else
  pass "install.sh: no leftover {{WORKER_PATH}} token in the plist"
fi

q6_plist_path_value=""
if [[ -f "$q6_plist" ]]; then
  q6_plist_path_value="$(python3 -c '
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        d = plistlib.load(f)
    print(d.get("EnvironmentVariables", {}).get("PATH", ""))
except Exception as e:
    print("ERR " + str(e))
' "$q6_plist")"
fi
if [[ "$q6_plist_path_value" == "$q6_expected_worker_path" ]]; then
  pass "install.sh: plist PATH == cr_resolve_worker_path's output for the same PATH"
else
  fail "install.sh: plist PATH value" "expected [$q6_expected_worker_path] got [$q6_plist_path_value]"
fi

if [[ -f "$q6_plist" ]]; then
  if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$q6_plist" >/dev/null 2>&1; then
      pass "install.sh: rendered plist is well-formed XML (plutil -lint)"
    else
      fail "install.sh: plist XML" "plutil -lint reported malformed XML"
    fi
  else
    if python3 -c "import xml.dom.minidom, sys; xml.dom.minidom.parse(sys.argv[1])" "$q6_plist" >/dev/null 2>&1; then
      pass "install.sh: rendered plist is well-formed XML (xml.dom.minidom fallback)"
    else
      fail "install.sh: plist XML" "xml.dom.minidom failed to parse the rendered plist"
    fi
  fi
fi

# Open-box guide ships with the install (AGENTS.md + the CLAUDE.md pointer).
for q6_guide in AGENTS.md CLAUDE.md; do
  if [[ -f "$q6_prefix/$q6_guide" ]] && cmp -s "$REPO_DIR/$q6_guide" "$q6_prefix/$q6_guide"; then
    pass "install.sh: copies $q6_guide into the prefix"
  else
    fail "install.sh: $q6_guide in prefix" "missing or differs at $q6_prefix/$q6_guide"
  fi
done
# ── Q6b: --mode byoa with NO --prefix / --env-file → the owner folder layout.
q6b_home="$(mktemp -d)"
mkdir -p "$q6b_home/.cfw-render"
q6b_env="$q6b_home/.cfw-render/cfw-render.env"
printf 'CFW_API_BASE=http://127.0.0.1:1\nCFW_RENDER_WORKER_KEY=cfw_render_q6bkey\n' > "$q6b_env"
chmod 644 "$q6b_env"
(
  export HOME="$q6b_home"
  export PATH="$q6_test_path"
  export PLAYWRIGHT_BROWSERS_PATH="$q6_browser_cache"
  # [M2-04] install.sh now bootout/bootstraps the LaunchAgent on re-run; never
  # load a real job from the test suite.
  export CFW_RENDER_INSTALL_NO_LAUNCHCTL=1
  "$REPO_DIR/install/install.sh" --mode byoa >"$q6b_home/install.log" 2>&1
)
q6b_app="$q6b_home/CFW Render/app"
if [[ -x "$q6b_app/bin/cfw-render.sh" && -f "$q6b_app/skills/index.json" && -f "$q6b_app/AGENTS.md" ]]; then
  pass "install.sh --mode byoa: default prefix is '\$HOME/CFW Render/app' (bin, skills, AGENTS.md)"
else
  fail "install.sh: default byoa prefix" "missing under $q6b_app — install.log tail: $(tail -15 "$q6b_home/install.log" 2>/dev/null)"
fi
if [[ -d "$q6b_home/CFW Render/outputs" && -d "$q6b_home/CFW Render/logs" ]]; then
  pass "install.sh --mode byoa: creates 'CFW Render/outputs' and 'CFW Render/logs'"
else
  fail "install.sh: visible folders" "$(ls -la "$q6b_home/CFW Render" 2>&1 | tr '\n' ' ')"
fi
q6b_mode="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$q6b_env" 2>/dev/null)"
if [[ "$q6b_mode" == "0o600" ]]; then
  pass "install.sh --mode byoa: settings file ~/.cfw-render/cfw-render.env is mode 600"
else
  fail "install.sh: env file mode" "expected 0o600, got $q6b_mode"
fi
q6b_plist_check="$(python3 -c '
import plistlib, sys
home = sys.argv[2]
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
want = {
  "program": home + "/CFW Render/app/bin/cfw-render.sh",
  "env": home + "/.cfw-render/cfw-render.env",
  "out": home + "/CFW Render/logs/cfw-render.out.log",
  "err": home + "/CFW Render/logs/cfw-render.err.log",
}
got = {
  "program": d.get("ProgramArguments", [""])[0],
  "env": d.get("EnvironmentVariables", {}).get("CFW_RENDER_ENV", ""),
  "out": d.get("StandardOutPath", ""),
  "err": d.get("StandardErrorPath", ""),
}
bad = [k + "=" + repr(got[k]) for k in want if got[k] != want[k]]
print("OK" if not bad else "BAD " + "; ".join(bad))
' "$q6b_home/Library/LaunchAgents/com.cfw.render.plist" "$q6b_home" 2>&1)"
if [[ "$q6b_plist_check" == "OK" ]]; then
  pass "install.sh --mode byoa: plist runs from 'CFW Render/app', reads ~/.cfw-render/cfw-render.env, logs to 'CFW Render/logs'"
else
  fail "install.sh: byoa plist paths" "$q6b_plist_check"
fi
if [[ -s "$q6b_home/.cfw-render/worker-id" && ! -e "$q6b_home/cfw-render-scratch" && ! -e "$q6b_home/cfw-render" && ! -e "$q6b_home/ecosystem" ]]; then
  pass "install.sh --mode byoa: worker-id in ~/.cfw-render; nothing else sprayed into \$HOME"
else
  fail "install.sh: stray folders" "home has: $(ls -A "$q6b_home" | tr '\n' ' ')"
fi
if grep -qF "finished renders: $q6b_home/CFW Render/outputs/<brand>/" "$q6b_home/install.log"; then
  pass "install.sh --mode byoa: prints where renders, the app and logs live"
else
  fail "install.sh: where-things-are summary" "not in install.log"
fi

# ── Q6c: an older install whose settings file is only at ~/ecosystem/vault
#    keeps using it (no --env-file given).
q6c_home="$(mktemp -d)"
mkdir -p "$q6c_home/ecosystem/vault"
printf 'CFW_API_BASE=http://127.0.0.1:1\nCFW_RENDER_WORKER_KEY=cfw_render_q6ckey\n' > "$q6c_home/ecosystem/vault/cfw-render.env"
(
  export HOME="$q6c_home"
  export PATH="$q6_test_path"
  export PLAYWRIGHT_BROWSERS_PATH="$q6_browser_cache"
  # [M2-04] install.sh now bootout/bootstraps the LaunchAgent on re-run; never
  # load a real job from the test suite.
  export CFW_RENDER_INSTALL_NO_LAUNCHCTL=1
  "$REPO_DIR/install/install.sh" --mode byoa >"$q6c_home/install.log" 2>&1
)
q6c_env="$(python3 -c '
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f).get("EnvironmentVariables", {}).get("CFW_RENDER_ENV", ""))
' "$q6c_home/Library/LaunchAgents/com.cfw.render.plist" 2>&1)"
if [[ "$q6c_env" == "$q6c_home/ecosystem/vault/cfw-render.env" ]]; then
  pass "install.sh --mode byoa: an existing legacy settings file keeps working"
else
  fail "install.sh: legacy env fallback" "plist CFW_RENDER_ENV=$q6c_env"
fi
rm -rf "$q6b_home" "$q6c_home"

rm -rf "$q6_home" "$q6_prefix" "$q6_custom"
rm -f "$q6_env"


echo ""
echo "=== Lint ==="
if "$REPO_DIR/scripts/lint.sh"; then
  pass "scripts/lint.sh"
else
  fail "scripts/lint.sh" "lint failed"
fi

echo ""
echo "=== Case 36: scripts/verify-skills-bundle.sh — committed skills/ bundle matches its index.json hashes (M2-06) ==="
if "$REPO_DIR/scripts/verify-skills-bundle.sh" --skills-dir "$REPO_DIR/skills" >/dev/null 2>&1; then
  pass "scripts/verify-skills-bundle.sh"
else
  fail "scripts/verify-skills-bundle.sh" "bundle verify failed — run it for the mismatch list"
fi

echo ""
echo "=== Case F: fan-out routes a native Claude alias to the worker's own login (CFW-299) ==="
cf_dir="$(mktemp -d)"; mkdir -p "$cf_dir/mockstate" "$cf_dir/work"
empty_queue > "$cf_dir/queue.json"
cf_port=$((MOCK_PORT_BASE + 95))
cf_pid="$(start_mock "$cf_dir/queue.json" "$cf_dir/mockstate" "$cf_port")"
: > "$cf_dir/no-keys.env"   # no live Ollama account at all — the 2026-09-29 state
(
  cd "$cf_dir" || exit 1
  export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
  export CFW_API_BASE="http://127.0.0.1:$cf_port"
  export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
  export CFW_ORDER_ID="order-fanout-test" CFW_WORKER_ID="worker-fanout-test"
  # the Director env always carries these (cfw-render.sh exports them); cr_event
  # runs under set -u and needs the state dir for its best-effort log line
  export CFW_RENDER_STATE_DIR="$cf_dir/cr-state" CFW_RENDER_SCRATCH_DIR="$cf_dir"
  export CFW_RENDER_FANOUT_MODELS="sonnet,glm-5.2"
  export CFW_RENDER_OLLAMA_KEYS_FILE="$cf_dir/no-keys.env"
  "$REPO_DIR/bin/cfw-render-subagent.sh" sonnet -p "render card 1" >/dev/null 2>&1
  echo "$?" > "$cf_dir/rc-native"
  "$REPO_DIR/bin/cfw-render-subagent.sh" glm-5.2 -p "render card 2" >/dev/null 2>&1
  echo "$?" > "$cf_dir/rc-ollama"
)
kill "$cf_pid" 2>/dev/null; wait "$cf_pid" 2>/dev/null
if [[ "$(cat "$cf_dir/rc-native")" == "0" ]]; then
  pass "fanout: native alias 'sonnet' is served (exit 0) with no Ollama key present"
else
  fail "fanout: native alias" "expected exit 0, got $(cat "$cf_dir/rc-native")"
fi
if grep -qx 'sonnet' "$cf_dir/work/.models-fanout" 2>/dev/null; then
  pass "fanout: served model 'sonnet' recorded in work/.models-fanout"
else
  fail "fanout: models-fanout" "expected 'sonnet' in work/.models-fanout, got: $(cat "$cf_dir/work/.models-fanout" 2>/dev/null)"
fi
if grep -qs -- '--model sonnet' "$cf_dir"/work/.subagent-*.out; then
  pass "fanout: native path invoked claude with --model sonnet"
else
  fail "fanout: native invocation" "no '--model sonnet' in $(ls "$cf_dir"/work/.subagent-*.out 2>/dev/null)"
fi
if [[ "$(cat "$cf_dir/rc-ollama")" != "0" ]]; then
  pass "fanout: Ollama model with no live key fails loudly (non-zero), never hangs"
else
  fail "fanout: ollama without keys" "expected non-zero exit, got 0"
fi
if grep -q '"kind": "subagent"' "$cf_dir/mockstate/calls.jsonl" 2>/dev/null; then
  pass "fanout: native subagent event reached the server"
else
  fail "fanout: subagent event" "no kind=subagent append_render_event in mock calls"
fi

echo "=== Case 15: check-no-handle-defaults.sh red — FAILs on a literal shell handle default (CFW-354) ==="
c354_dirty_base="$(mktemp -d)"
mkdir -p "$c354_dirty_base/p-dirty-recipe"
printf '# setup\nCTA_TEXT="${CTA_TEXT:-FOLLOW}"\nCTA_HANDLE="${CTA_HANDLE:-@someone}"\n' > "$c354_dirty_base/p-dirty-recipe/SKILL.md"
c354_dirty_out="$("$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_dirty_base" 2>&1)"
c354_dirty_rc=$?
if [[ "$c354_dirty_rc" == "1" ]]; then
  pass "check-no-handle-defaults.sh: FAILs (exit 1) on a literal \${VAR:-@…} default (red/green proof, CFW-354)"
else
  fail "check-no-handle-defaults.sh: red case" "expected exit 1, got $c354_dirty_rc: $c354_dirty_out"
fi
if grep -q 'p-dirty-recipe/SKILL.md:3' <<< "$c354_dirty_out"; then
  pass "check-no-handle-defaults.sh: red case names the offending path:line"
else
  fail "check-no-handle-defaults.sh: red case output" "expected 'p-dirty-recipe/SKILL.md:3' in: $c354_dirty_out"
fi
rm -rf "$c354_dirty_base"

echo "=== Case 15a: check-no-handle-defaults.sh red — FAILs on a literal @mr.growthguide anywhere (CFW-354) ==="
c354_leak_base="$(mktemp -d)"
mkdir -p "$c354_leak_base/p-dirty-recipe"
printf 'Follow @mr.growthguide for more.\n' > "$c354_leak_base/p-dirty-recipe/NOTE.md"
if "$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_leak_base" >/dev/null 2>&1; then
  fail "check-no-handle-defaults.sh: leaked-handle red case" "expected exit 1 on a literal @mr.growthguide in NOTE.md"
else
  pass "check-no-handle-defaults.sh: FAILs on a literal @mr.growthguide outside brand-overrides/ (CFW-354)"
fi
rm -rf "$c354_leak_base"

echo "=== Case 15a1: check-no-handle-defaults.sh red — a backslash-continued default can't dodge the gate (CFW-354 QA F1) ==="
c354_cont_base="$(mktemp -d)"
mkdir -p "$c354_cont_base/p-dirty-recipe"
printf 'x\nCTA_HANDLE="${CTA_HANDLE:-\\\n@split}"\n' > "$c354_cont_base/p-dirty-recipe/SKILL.md"
c354_cont_out="$("$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_cont_base" 2>&1)"
c354_cont_rc=$?
if [[ "$c354_cont_rc" == "1" && "$c354_cont_out" == *"p-dirty-recipe/SKILL.md:2"* ]]; then
  pass "check-no-handle-defaults.sh: FAILs on a \${VAR:-@…} default split across a backslash continuation, naming line 2"
else
  fail "check-no-handle-defaults.sh: continuation red case" "expected exit 1 naming p-dirty-recipe/SKILL.md:2, got $c354_cont_rc: $c354_cont_out"
fi
rm -rf "$c354_cont_base"

echo "=== Case 15a2: check-no-handle-defaults.sh — rendered kicker MR GROWTH GUIDE is red, prose 'Mr Growth Guide' is green (CFW-354 QA F2) ==="
c354_kick_base="$(mktemp -d)"
mkdir -p "$c354_kick_base/p-dirty-recipe"
printf '{"type":"kicker","text":"MR GROWTH GUIDE"}\n' > "$c354_kick_base/p-dirty-recipe/cta-card.json"
if "$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_kick_base" >/dev/null 2>&1; then
  fail "check-no-handle-defaults.sh: kicker red case" "expected exit 1 on a literal MR GROWTH GUIDE kicker"
else
  pass "check-no-handle-defaults.sh: FAILs on the rendered kicker literal MR GROWTH GUIDE outside brand-overrides/ (CFW-354)"
fi
printf 'This avatar serves both CFW and Mr Growth Guide.\n' > "$c354_kick_base/p-dirty-recipe/cta-card.json"
c354_kick_out="$("$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_kick_base" 2>&1)"
c354_kick_rc=$?
if [[ "$c354_kick_rc" == "0" ]]; then
  pass "check-no-handle-defaults.sh: prose 'Mr Growth Guide' (not the rendered kicker) stays clean"
else
  fail "check-no-handle-defaults.sh: kicker prose green case" "expected exit 0, got $c354_kick_rc: $c354_kick_out"
fi
rm -rf "$c354_kick_base"

echo "=== Case 15b: check-no-handle-defaults.sh green — empty default, prose @handle, brand.json handle all clean (CFW-354) ==="
c354_clean_base="$(mktemp -d)"
mkdir -p "$c354_clean_base/p-clean-recipe/brand-overrides/x"
printf 'CTA_HANDLE="${CTA_HANDLE:-}"\nAdd the `@handle` if known.\n' > "$c354_clean_base/p-clean-recipe/SKILL.md"
printf '{"cta":{"handle":"@legit"}}\n' > "$c354_clean_base/p-clean-recipe/brand-overrides/x/brand.json"
c354_clean_out="$("$REPO_DIR/scripts/check-no-handle-defaults.sh" --skills-dir "$c354_clean_base" 2>&1)"
c354_clean_rc=$?
if [[ "$c354_clean_rc" == "0" ]]; then
  pass "check-no-handle-defaults.sh: PASSes on empty default + prose @handle + brand-overrides/<slug>/brand.json handle"
else
  fail "check-no-handle-defaults.sh: green case" "expected exit 0, got $c354_clean_rc: $c354_clean_out"
fi
rm -rf "$c354_clean_base"

echo "=== Case 15c: static guard — no literal handle default anywhere in the committed skills/ bundle (CFW-354) ==="
if "$REPO_DIR/scripts/check-no-handle-defaults.sh" >/dev/null 2>&1; then
  pass "static guard: committed skills/ bundle has no literal handle default"
else
  c354_real_out="$("$REPO_DIR/scripts/check-no-handle-defaults.sh" 2>&1)"
  fail "static guard: literal handle default found in committed bundle" "$c354_real_out"
fi

echo "=== Case 15d: Spotlight end card (step 8) — handle/kicker layers are per-brand, omitted when unset (CFW-354) ==="
c354_cta_py="$REPO_DIR/skills/p-reels-spotlight/scripts/cta-card.py"
if [[ -f "$c354_cta_py" ]]; then
  c354_cta_dir="$(mktemp -d)"
  printf '{"brand":{"bg":"#0F172A","accent":"#F97316","fg":"#F1F5F9"}}\n' > "$c354_cta_dir/plan.json"
  c354_cta_types() {  # $1 = out.json → comma-joined layer types
    python3 -c 'import json,sys; print(",".join(l.get("type","") for l in json.load(open(sys.argv[1]))["layers"]))' "$1" 2>/dev/null
  }
  if CTA_HANDLE=@brand_a BRAND_NAME='Brand A' python3 "$c354_cta_py" "$c354_cta_dir/plan.json" "$c354_cta_dir/a.json" >/dev/null 2>&1; then
    c354_a_types="$(c354_cta_types "$c354_cta_dir/a.json")"
    if [[ "$c354_a_types" == "kicker,hero,handle,arrow" ]]; then
      pass "cta-card.py: with CTA_HANDLE + BRAND_NAME set, layers are exactly kicker,hero,handle,arrow"
    else
      fail "cta-card.py: branded layer types" "expected kicker,hero,handle,arrow, got '$c354_a_types'"
    fi
    c354_a_handle="$(python3 -c 'import json,sys; print(next((l.get("text","") for l in json.load(open(sys.argv[1]))["layers"] if l.get("type")=="handle"), ""))' "$c354_cta_dir/a.json" 2>/dev/null)"
    if [[ "$c354_a_handle" == "@brand_a" ]]; then
      pass "cta-card.py: handle layer text is the brand's own handle (@brand_a)"
    else
      fail "cta-card.py: handle layer text" "expected '@brand_a', got '$c354_a_handle'"
    fi
  else
    fail "cta-card.py: branded run" "python3 cta-card.py exited non-zero with CTA_HANDLE=@brand_a BRAND_NAME='Brand A'"
  fi
  if CTA_HANDLE="" BRAND_NAME="" python3 "$c354_cta_py" "$c354_cta_dir/plan.json" "$c354_cta_dir/b.json" >/dev/null 2>&1; then
    c354_b_types="$(c354_cta_types "$c354_cta_dir/b.json")"
    if [[ "$c354_b_types" == "hero,arrow" ]]; then
      pass "cta-card.py: with CTA_HANDLE and BRAND_NAME empty, layers are exactly hero,arrow"
    else
      fail "cta-card.py: unbranded layer types" "expected hero,arrow, got '$c354_b_types'"
    fi
    if ! grep -qi 'growthguide' "$c354_cta_dir/b.json" && ! grep -q '@' "$c354_cta_dir/b.json"; then
      pass "cta-card.py: unbranded output contains no growthguide and no @"
    else
      fail "cta-card.py: unbranded output leak" "found growthguide or @ in: $(cat "$c354_cta_dir/b.json")"
    fi
  else
    fail "cta-card.py: unbranded run" "python3 cta-card.py exited non-zero with CTA_HANDLE='' BRAND_NAME=''"
  fi
  rm -rf "$c354_cta_dir"
else
  fail "cta-card.py: Spotlight end-card script present" "expected $c354_cta_py (arrives with the CFW-354 skills re-sync) — not found"
fi

echo "=== Case 16: recipe manifest v1 — Spotlight manifest validates (M1-01) ==="
c16_validator="$REPO_DIR/scripts/validate-manifests.py"
c16_fixtures="$TEST_DIR/fixtures/manifests"
c16_out="$(python3 "$c16_validator" 2>&1)"
c16_rc=$?
if [[ "$c16_rc" == "0" ]] && grep -q 'OK .*skills/p-reels-spotlight/manifest.json' <<< "$c16_out"; then
  pass "validate-manifests.py: committed skills/*/manifest.json (Spotlight) validate, exit 0"
else
  fail "validate-manifests.py: committed manifests" "expected exit 0 + OK line for p-reels-spotlight, got rc=$c16_rc: $c16_out"
fi
c16_spot="$REPO_DIR/skills/p-reels-spotlight/manifest.json"
c16_shape="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m["recipeVersion"], ",".join(s["id"] for s in m["steps"]), ",".join(i["id"] for i in m["inputs"]), sum(s["weight"] for s in m["steps"]))
' "$c16_spot" 2>/dev/null)"
c16_want="2026.10.2 research,script,prepare_footage,transcribe,plan_edit,plan_broll,render_scenes,assemble,final_checks talking_head,broll,cta 100"
if [[ "$c16_shape" == "$c16_want" ]]; then
  pass "Spotlight manifest: recipeVersion 2026.10.2 (M1-09), 9 steps in contract order, 3 inputs, computer weights sum to 100"
else
  fail "Spotlight manifest shape" "expected '$c16_want', got '$c16_shape'"
fi
c16_steps_dir="$REPO_DIR/skills/p-reels-spotlight"
c16_missing_ins=""
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  [[ -f "$c16_steps_dir/$rel" ]] || c16_missing_ins="$c16_missing_ins $rel"
done < <(python3 -c 'import json,sys; [print(s.get("instructions","")) for s in json.load(open(sys.argv[1]))["steps"] if s["runsOn"]=="computer"]' "$c16_spot" 2>/dev/null)
if [[ -z "$c16_missing_ins" ]]; then
  pass "Spotlight manifest: every computer step's instructions file exists under steps/"
else
  fail "Spotlight manifest: instructions files" "missing:$c16_missing_ins"
fi
# [M2-06 batch 1] the five new manifests + Spotlight: OK lines, instructions files, providers, no c-composio.
# M2-06 batch 1 (reels family), batch 2 (image recipes) and p-reels-faceless (batch 3, landed with batch 2 — the
# sync regenerates the whole bundle, so every complete manifest at the source library ships together).
c16_batch="p-reels-spotlight p-reels-pip p-reels-split p-reels-spotlight-heygen p-reels-pip-heygen p-reels-split-heygen p-carousel p-ai-image p-gfx-image p-ai-character p-reels-faceless p-clone-reel p-longform"
for c16_r in $c16_batch; do
  c16_m="$REPO_DIR/skills/$c16_r/manifest.json"
  if grep -q "OK .*skills/$c16_r/manifest.json" <<< "$c16_out"; then
    pass "validate-manifests.py: OK line for $c16_r"
  else
    fail "validate-manifests.py: $c16_r" "no OK line in: $c16_out"
  fi
  c16_missing_ins=""
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    [[ -f "$REPO_DIR/skills/$c16_r/$rel" ]] || c16_missing_ins="$c16_missing_ins $rel"
  done < <(python3 -c 'import json,sys; [print(s.get("instructions","")) for s in json.load(open(sys.argv[1]))["steps"] if s["runsOn"]=="computer"]' "$c16_m" 2>/dev/null)
  if [[ -z "$c16_missing_ins" && -f "$REPO_DIR/skills/$c16_r/steps/_shared.md" ]]; then
    pass "$c16_r manifest: every computer step's instructions file + steps/_shared.md exist"
  else
    fail "$c16_r manifest: instructions files" "missing:$c16_missing_ins (_shared.md present: $([[ -f "$REPO_DIR/skills/$c16_r/steps/_shared.md" ]] && echo yes || echo no))"
  fi
  c16_prov="$(python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1]))["needs"]["providers"])))' "$c16_m" 2>/dev/null)"
  case "$c16_r" in
    p-reels-split-heygen) c16_prov_want="elevenlabs,heygen" ;;
    *-heygen)             c16_prov_want="heygen" ;;
    p-ai-image|p-ai-character) c16_prov_want="kie" ;;
    p-reels-faceless)     c16_prov_want="elevenlabs" ;;
    p-clone-reel)         c16_prov_want="elevenlabs,heygen" ;;
    p-longform)           c16_prov_want="elevenlabs,heygen" ;;
    *)                    c16_prov_want="" ;;
  esac
  if [[ "$c16_prov" == "$c16_prov_want" ]]; then
    pass "$c16_r manifest: needs.providers = [${c16_prov_want}]"
  else
    fail "$c16_r manifest: needs.providers" "expected '$c16_prov_want', got '$c16_prov'"
  fi
done
if ! grep -q 'c-composio' <<< "$c16_out"; then
  pass "validate-manifests.py: no c-composio line (component, not a recipe manifest)"
else
  fail "validate-manifests.py: c-composio" "unexpected line: $(grep c-composio <<< "$c16_out")"
fi
c16_shape_h="$(python3 -c '
import json, sys
for r in sys.argv[1:]:
    m = json.load(open(r)); st = m["steps"]
    print(r.split("/")[-2], st[0]["id"], st[0]["runsOn"], ",".join(st[0].get("canAsk", [])), m["inputs"][0]["id"], m["inputs"][0]["neededAt"], sum(s["weight"] for s in st))
' "$REPO_DIR/skills/p-reels-spotlight-heygen/manifest.json" "$REPO_DIR/skills/p-reels-pip-heygen/manifest.json" "$REPO_DIR/skills/p-reels-split-heygen/manifest.json" 2>/dev/null)"
c16_shape_h_want="p-reels-spotlight-heygen generate_avatar computer script,avatar_id,voice_id script start 100
p-reels-pip-heygen generate_avatar computer script,avatar_id,voice_id script start 100
p-reels-split-heygen generate_avatar computer script,avatar_id,voice_id script start 100"
if [[ "$c16_shape_h" == "$c16_shape_h_want" ]]; then
  pass "-heygen manifests: leading generate_avatar (computer, canAsk script/avatar_id/voice_id), script neededAt start, weights sum to 100"
else
  fail "-heygen manifest shape" "expected '$c16_shape_h_want', got '$c16_shape_h'"
fi
# M2-06 batch 2: image recipes — deliverable.kind image, first input neededAt start, weights sum to 100.
c16_shape_i="$(python3 -c '
import json, sys
for r in sys.argv[1:]:
    m = json.load(open(r)); st = m["steps"]
    print(r.split("/")[-2], m["deliverable"]["kind"], len(st), m["inputs"][0]["id"], m["inputs"][0]["neededAt"], sum(s["weight"] for s in st))
' "$REPO_DIR/skills/p-carousel/manifest.json" "$REPO_DIR/skills/p-ai-image/manifest.json" "$REPO_DIR/skills/p-gfx-image/manifest.json" "$REPO_DIR/skills/p-ai-character/manifest.json" 2>/dev/null)"
c16_shape_i_want="p-carousel image 4 topic start 100
p-ai-image image 3 prompt start 100
p-gfx-image image 4 topic start 100
p-ai-character image 4 story_concept start 100"
if [[ "$c16_shape_i" == "$c16_shape_i_want" ]]; then
  pass "batch-2 image manifests: kind image, first input at start, weights sum to 100"
else
  fail "batch-2 image manifest shape" "expected '$c16_shape_i_want', got '$c16_shape_i'"
fi
# M2-06 batch 3: p-reels-faceless — research/script server alternative like Spotlight, script input at start.
c16_shape_f="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1])); st = m["steps"]
print(st[0]["id"], st[0]["runsOn"], st[1]["id"], st[1]["runsOn"], m["inputs"][0]["id"], m["inputs"][0]["neededAt"], sum(s["weight"] for s in st))
' "$REPO_DIR/skills/p-reels-faceless/manifest.json" 2>/dev/null)"
if [[ "$c16_shape_f" == "research server script server script start 100" ]]; then
  pass "p-reels-faceless manifest: research+script server steps, script input at start, weights sum to 100"
else
  fail "p-reels-faceless manifest shape" "got '$c16_shape_f'"
fi
# M2-06 batch 3: p-clone-reel + p-longform — first input at start, deliverable aspect, weights sum to 100.
c16_shape_b3="$(python3 -c '
import json, sys
for r in sys.argv[1:]:
    m = json.load(open(r)); st = m["steps"]
    print(r.split("/")[-2], m["deliverable"]["aspect"], len(st), m["inputs"][0]["id"], m["inputs"][0]["neededAt"], sum(s["weight"] for s in st))
' "$REPO_DIR/skills/p-clone-reel/manifest.json" "$REPO_DIR/skills/p-longform/manifest.json" 2>/dev/null)"
c16_shape_b3_want="p-clone-reel 9:16 5 source_reel start 100
p-longform 16:9 10 script start 100"
if [[ "$c16_shape_b3" == "$c16_shape_b3_want" ]]; then
  pass "batch-3 manifests: first input at start, aspect declared, weights sum to 100"
else
  fail "batch-3 manifest shape" "expected '$c16_shape_b3_want', got '$c16_shape_b3'"
fi
if python3 "$c16_validator" "$c16_fixtures/valid-minimal/manifest.json" >/dev/null 2>&1; then
  pass "validate-manifests.py: valid-minimal fixture passes (exit 0)"
else
  fail "validate-manifests.py: valid-minimal fixture" "expected exit 0"
fi

echo "=== Case 16a: validate-manifests.py red — canAsk names a missing input (M1-01) ==="
c16a_out="$(python3 "$c16_validator" "$c16_fixtures/bad-canask-unknown-input/manifest.json" 2>&1)"
c16a_rc=$?
if [[ "$c16a_rc" == "1" ]]; then
  pass "validate-manifests.py: exit 1 when canAsk references an unknown input"
else
  fail "validate-manifests.py: canAsk red case" "expected exit 1, got $c16a_rc: $c16a_out"
fi
if grep -q "steps\[prepare\].canAsk: references unknown input 'missing_input'" <<< "$c16a_out"; then
  pass "validate-manifests.py: canAsk error names the step (prepare) and the input (missing_input)"
else
  fail "validate-manifests.py: canAsk error text" "expected step+input named in: $c16a_out"
fi

echo "=== Case 16b: validate-manifests.py red — two steps share an id (M1-01) ==="
c16b_out="$(python3 "$c16_validator" "$c16_fixtures/bad-duplicate-step-id/manifest.json" 2>&1)"
c16b_rc=$?
if [[ "$c16b_rc" == "1" ]] && grep -q "steps: duplicate id 'prepare'" <<< "$c16b_out"; then
  pass "validate-manifests.py: exit 1 + names the duplicate step id"
else
  fail "validate-manifests.py: duplicate step id" "expected exit 1 + duplicate id 'prepare', got rc=$c16b_rc: $c16b_out"
fi

echo "=== Case 16c: validate-manifests.py red — a step's instructions file is missing (M1-01) ==="
c16c_out="$(python3 "$c16_validator" "$c16_fixtures/bad-missing-instructions/manifest.json" 2>&1)"
c16c_rc=$?
if [[ "$c16c_rc" == "1" ]]; then
  pass "validate-manifests.py: exit 1 when a step's instructions file is missing"
else
  fail "validate-manifests.py: missing instructions red case" "expected exit 1, got $c16c_rc: $c16c_out"
fi
if grep -q "steps\[finish\].instructions: file not found: .*bad-missing-instructions/steps/99-does-not-exist.md" <<< "$c16c_out"; then
  pass "validate-manifests.py: missing-instructions error names the step and the path"
else
  fail "validate-manifests.py: missing instructions error text" "expected path steps/99-does-not-exist.md in: $c16c_out"
fi

echo "=== Case 16d: validate-manifests.py red — alternatives[].runsSteps names a missing step; hand checks hold without jsonschema (M1-01) ==="
c16d_out="$(python3 "$c16_validator" "$c16_fixtures/bad-runssteps-unknown-step/manifest.json" 2>&1)"
c16d_rc=$?
if [[ "$c16d_rc" == "1" ]] && grep -q "inputs\[clip\].alternatives\[0\].runsSteps: references unknown step 'nope'" <<< "$c16d_out"; then
  pass "validate-manifests.py: exit 1 + names the input, alternative and unknown step"
else
  fail "validate-manifests.py: runsSteps red case" "expected exit 1 + unknown step 'nope', got rc=$c16d_rc: $c16d_out"
fi
# Same four red fixtures with the optional jsonschema package masked out, so the
# gate is proven identical on a machine without it (runtime-free repo rule).
c16d_nojs="$(python3 - "$c16_validator" "$c16_fixtures" <<'PY' 2>&1
import runpy, sys
validator, fixtures = sys.argv[1], sys.argv[2]
sys.modules["jsonschema"] = None
bad = ["bad-canask-unknown-input", "bad-duplicate-step-id", "bad-missing-instructions", "bad-runssteps-unknown-step"]
sys.argv = [validator] + [f"{fixtures}/{b}/manifest.json" for b in bad] + [f"{fixtures}/valid-minimal/manifest.json"]
try:
    runpy.run_path(validator, run_name="__main__")
except SystemExit as e:
    print(f"RC={e.code}")
PY
)"
if grep -q '^RC=1$' <<< "$c16d_nojs" && grep -q 'FAIL — 4 of 5' <<< "$c16d_nojs"; then
  pass "validate-manifests.py: without jsonschema, hand-written checks still fail exactly the 4 bad fixtures"
else
  fail "validate-manifests.py: no-jsonschema mode" "expected RC=1 and 'FAIL — 4 of 5' in: $c16d_nojs"
fi

echo "=== Case 18: step harness mock — capability-gated claim, report_render_step, control files (M1-08 b) ==="
c18_dir="$(mktemp -d)"
c18_port=$((MOCK_PORT_BASE + 900))
c18_state="$c18_dir/mockstate"; c18_ctl="$c18_dir/control"
mkdir -p "$c18_state" "$c18_ctl"
c18_manifest="$REPO_DIR/skills/p-reels-spotlight/manifest.json"
python3 -c '
import json, sys
print(json.dumps([{"id": "order-m1", "brandId": "brand-1", "workspaceId": "ws-1", "kind": "video",
  "recipe": "p-reels-spotlight", "recipeVersion": "2026.10.2", "manifest": sys.argv[1],
  "status": "queued", "taskOrder": {"version": 1, "orderId": "order-m1"}, "priority": 0, "attempts": 1}]))
' "$c18_manifest" > "$c18_dir/queue.json"
c18_pid="$(CFW_MOCK_CONTROL_DIR="$c18_ctl" start_mock "$c18_dir/queue.json" "$c18_state" "$c18_port")"
c18_run() {
  # c18_run <bash-snippet>: sources the lib against the Case-18 mock; prints stdout, returns the snippet's rc.
  CFW_API_BASE="http://127.0.0.1:$c18_port" CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000" \
    bash -c 'set -uo pipefail; source "$1"; shift; eval "$*"' _ "$REPO_DIR/bin/cfw-render-lib.sh" "$1"
}
c18_caps='{"engine":"codex","os":"macos","manifests":[{"recipe":"p-reels-spotlight","recipeVersion":"2026.10.2"}]}'

echo "--- 18a: claim without capabilities → order null"
c18a_out="$(c18_run 'cr_mcp_call_soft claim_render_order "{\"workerId\":\"w1\"}"')"
if [[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["order"])' <<< "$c18a_out")" == "None" ]]; then
  pass "claim: manifest order withheld when claim carries no capabilities"
else
  fail "claim: no-capabilities" "expected order null, got: $c18a_out"
fi

echo "--- 18b: claim with matching capabilities → attempt/manifest/resumeFromStepId"
c18b_out="$(c18_run "cr_mcp_call_soft claim_render_order '{\"workerId\":\"w1\",\"capabilities\":$c18_caps}'")"
c18b_shape="$(python3 -c '
import json, sys
o = json.load(sys.stdin)["order"]
print(o["attempt"]["id"], o["attempt"]["number"], o["manifest"]["recipeVersion"], o["resumeFromStepId"], o["savedOutputs"], o["inputs"], o["answers"])
' <<< "$c18b_out" 2>/dev/null)"
if [[ "$c18b_shape" == "att_1 1 2026.10.2 prepare_footage [] {} {}" ]]; then
  pass "claim: capability match returns attempt att_1/1, manifest, resumeFromStepId=prepare_footage, empty savedOutputs/inputs/answers"
else
  fail "claim: capabilities match" "expected 'att_1 1 2026.10.2 prepare_footage [] {} {}', got '$c18b_shape' from: $c18b_out"
fi

echo "--- 18c: report seq 1,1,2 → reports.ndjson has 2 lines, 2nd reply duplicate:true"
c18c_1="$(c18_run 'cr_report_step order-m1 w1 att_1 1 step_started "{\"stepId\":\"prepare_footage\"}"')"
c18c_2="$(c18_run 'cr_report_step order-m1 w1 att_1 1 step_started "{\"stepId\":\"prepare_footage\"}"')"
c18c_3="$(c18_run 'cr_report_step order-m1 w1 att_1 2 step_completed "{\"stepId\":\"prepare_footage\",\"outputs\":[{\"id\":\"o1\",\"url\":\"https://media.cfw.social/x.mp4\"}]}"')"
c18c_flags="$(python3 -c '
import json, sys
r = [json.loads(x) for x in sys.argv[1:]]
print(" ".join("%s/%s/%s" % (x["ok"], x["duplicate"], x["directive"]) for x in r))
' "$c18c_1" "$c18c_2" "$c18c_3" 2>/dev/null)"
c18c_lines="$(wc -l < "$c18_ctl/reports.ndjson" | tr -d ' ')"
c18c_seqs="$(python3 -c 'import json,sys; print(",".join(str(json.loads(l)["seq"]) for l in open(sys.argv[1]) if l.strip()))' "$c18_ctl/reports.ndjson")"
if [[ "$c18c_flags" == "True/False/continue True/True/continue True/False/continue" && "$c18c_seqs" == "1,2" && "$c18c_lines" == "2" ]]; then
  pass "report_render_step: seq 1,1,2 → second reply duplicate:true (stored nothing); reports.ndjson has 2 lines in order (1,2)"
else
  fail "report_render_step: duplicate seq" "flags='$c18c_flags' seqs='$c18c_seqs' lines=$c18c_lines"
fi

echo "--- 18d: seq 0 after 2 → seq_out_of_order"
c18d_out="$(c18_run 'cr_report_step order-m1 w1 att_1 0 heartbeat')"
if [[ "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d.get("code"), d["directive"])' <<< "$c18d_out")" == "False seq_out_of_order continue" ]]; then
  pass "report_render_step: unseen seq below last → ok:false code seq_out_of_order directive continue"
else
  fail "report_render_step: seq_out_of_order" "got: $c18d_out"
fi

echo "--- 18e: control file directive=cancel → directive cancel"
printf 'cancel' > "$c18_ctl/directive"
c18e_out="$(c18_run 'cr_report_step order-m1 w1 att_1 3 heartbeat')"
rm -f "$c18_ctl/directive"
if [[ "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d["directive"])' <<< "$c18e_out")" == "True cancel" ]]; then
  pass "report_render_step: \$CFW_MOCK_CONTROL_DIR/directive=cancel is echoed as directive cancel"
else
  fail "report_render_step: scripted cancel" "got: $c18e_out"
fi

echo "--- 18f: down file → cr_mcp_call_soft returns 75, prints nothing"
touch "$c18_ctl/down"
c18f_out="$(c18_run 'cr_report_step order-m1 w1 att_1 4 heartbeat 2>/dev/null; echo "rc=$?"')"
rm -f "$c18_ctl/down"
if [[ "$c18f_out" == "rc=75" ]]; then
  pass "cr_mcp_call_soft: server down (503) → exit 75 (EX_TEMPFAIL), empty stdout, caller survives"
else
  fail "cr_mcp_call_soft: down" "expected 'rc=75' only, got: $c18f_out"
fi
kill "$c18_pid" 2>/dev/null; wait "$c18_pid" 2>/dev/null
rm -rf "$c18_dir"

if local_checkpoint_cases; then
  pass "local checkpoint persistence and gated recovery"
else
  fail "local checkpoint persistence and gated recovery" "see offline assertions above"
fi

echo "=== Case 19: step harness end-to-end — cfw-render.sh claim branch + cr_harness_run + fake engine (M1-08 c) ==="
c19_manifest="$REPO_DIR/test/fixtures/manifests/harness-3step/manifest.json"
# c19_setup <dir> <port> [inputs-json] — seed a manifest order, skills dir, start mock. Sets c19_pid/c19_ctl/c19_state.
c19_setup() {
  local dir="$1" port="$2" inputs="${3:-{\}}"
  c19_state="$dir/mockstate"; c19_ctl="$dir/control"
  mkdir -p "$c19_state" "$c19_ctl" "$dir/skills/harness-3step" "$dir/cr-scratch" "$dir/cr-state"
  cp "$c19_manifest" "$dir/skills/harness-3step/manifest.json"
  python3 -c '
import json, sys
print(json.dumps([{"id": "order-h1", "brandId": "brand-1", "workspaceId": "ws-1", "kind": "video",
  "recipe": "harness-3step", "recipeVersion": "1.0.0", "manifest": sys.argv[1], "inputs": json.loads(sys.argv[2]),
  "status": "queued", "priority": 0, "attempts": 1,
  "taskOrder": {"version": 1, "orderId": "order-h1", "brand": {"id": "brand-1", "slug": "test-brand", "brief": "b"},
                "kind": "video", "recipe": "harness-3step", "workspaceId": "ws-1", "intent": "t", "ingredients": [], "targets": ["instagram"]}}]))
' "$c19_manifest" "$inputs" > "$dir/queue.json"
  c19_pid="$(CFW_MOCK_CONTROL_DIR="$c19_ctl" start_mock "$dir/queue.json" "$c19_state" "$port")"
}
# c19_worker <dir> <port> [env assignments...] — one tick of cfw-render.sh against the mock.
c19_worker() {
  local dir="$1" port="$2"; shift 2
  (
    export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
    export CFW_API_BASE="http://127.0.0.1:$port"
    export CFW_RENDER_TEST_MEDIA_BASE_URL="$CFW_API_BASE"
    export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
    export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
    export CFW_RENDER_STATE_DIR="$dir/cr-state"
    export CFW_RENDER_LOG_DIR="$dir/cr-state" CFW_RENDER_KEEP_OUTPUTS=0
    export CFW_RENDER_SCRATCH="$dir/cr-scratch"
    export CFW_RENDER_SKILLS_DIR="$dir/skills"
    export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
    export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
    export CFW_RENDER_ENGINE_CMD="$TEST_DIR/fake-engine.sh"
    export CFW_RENDER_HEARTBEAT_SEC=1
    export CFW_RENDER_CONCURRENCY=1
    export CFW_WORKER_ID="w-h"
    export CFW_RENDER_UPLOAD_MODE=multipart
    for kv in "$@"; do export "${kv?}"; done
    "$REPO_DIR/bin/cfw-render.sh" > "$dir/worker.out" 2>&1
  )
}
c19_events() { python3 -c '
import json, sys
print(" ".join("%s:%s" % (d["event"], d.get("stepId") or "-") for d in (json.loads(l) for l in open(sys.argv[1]) if l.strip()) if d["event"] != "heartbeat"))' "$1" 2>/dev/null; }
c19_seqs_ok() { python3 -c '
import json, sys
s = [json.loads(l)["seq"] for l in open(sys.argv[1]) if l.strip()]
print("ok" if s == sorted(s) and len(s) == len(set(s)) else "bad:%s" % s)' "$1" 2>/dev/null; }
c19_completed() { grep -c '"tool": "complete_render_order".*"ok": true' "$1/mockstate/calls.jsonl" 2>/dev/null || true; }

echo "--- 19a: full run — a, c run; b skipped; attempt_completed; complete_render_order called"
c19a="$(mktemp -d)"; c19_setup "$c19a" $((MOCK_PORT_BASE + 910))
c19_worker "$c19a" $((MOCK_PORT_BASE + 910))
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19a_ev="$(c19_events "$c19_ctl/reports.ndjson")"
if [[ "$c19a_ev" == "step_started:a step_completed:a step_skipped:b step_started:c step_completed:c attempt_completed:-" && "$(c19_seqs_ok "$c19_ctl/reports.ndjson")" == "ok" && "$(c19_completed "$c19a")" == "1" ]]; then
  pass "harness: a→(b skipped)→c→attempt_completed, strictly increasing seq, complete_render_order ok"
else
  fail "harness: full run" "events='$c19a_ev' seqs=$(c19_seqs_ok "$c19_ctl/reports.ndjson") completed=$(c19_completed "$c19a"); worker.out: $(tail -5 "$c19a/worker.out")"
fi
rm -rf "$c19a"

echo "--- 19b: broll present → b runs"
c19b="$(mktemp -d)"; c19_setup "$c19b" $((MOCK_PORT_BASE + 911)) '{"broll":[{"url":"https://cfw-media.test/broll.mp4"}]}'
c19_worker "$c19b" $((MOCK_PORT_BASE + 911))
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19b_ev="$(c19_events "$c19_ctl/reports.ndjson")"
if [[ "$c19b_ev" == "step_started:a step_completed:a step_started:b step_completed:b step_started:c step_completed:c attempt_completed:-" ]]; then
  pass "harness: when.inputPresent=broll satisfied → b runs"
else
  fail "harness: broll present" "events='$c19b_ev'"
fi
rm -rf "$c19b"

echo "--- 19c: c fails its check twice (maxCheckRetries 2) → completes"
c19c="$(mktemp -d)"; c19_setup "$c19c" $((MOCK_PORT_BASE + 912))
c19_worker "$c19c" $((MOCK_PORT_BASE + 912)) FAKE_ENGINE_FAIL_STEP=c FAKE_ENGINE_FAIL_CHECK_TIMES=2
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19c_ev="$(c19_events "$c19_ctl/reports.ndjson")"
if [[ "$c19c_ev" == *"step_started:c step_started:c step_started:c step_completed:c attempt_completed:-" && "$(c19_completed "$c19c")" == "1" ]]; then
  pass "harness: check fails 2× within maxCheckRetries=2 → third run completes"
else
  fail "harness: retries within cap" "events='$c19c_ev'"
fi
rm -rf "$c19c"

echo "--- 19d: c fails 5× → step_failed c/z_ok then attempt_failed"
c19d="$(mktemp -d)"; c19_setup "$c19d" $((MOCK_PORT_BASE + 913))
c19_worker "$c19d" $((MOCK_PORT_BASE + 913)) FAKE_ENGINE_FAIL_STEP=c FAKE_ENGINE_FAIL_CHECK_TIMES=5
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19d_ev="$(c19_events "$c19_ctl/reports.ndjson")"
c19d_chk="$(python3 -c '
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["event"] == "step_failed": print(d["stepId"], d["checks"][0]["id"], d["checks"][0]["passed"])' "$c19_ctl/reports.ndjson" 2>/dev/null)"
if [[ "$c19d_ev" == *"step_failed:c attempt_failed:c" && "$c19d_chk" == "c z_ok False" && "$(c19_completed "$c19d")" == "0" ]]; then
  pass "harness: retries exhausted → step_failed {c, z_ok:false} then attempt_failed; no complete"
else
  fail "harness: retries exhausted" "events='$c19d_ev' chk='$c19d_chk'"
fi
rm -rf "$c19d"

echo "--- 19e: directive cancel after a → attempt_cancelled, no c"
c19e="$(mktemp -d)"; c19_setup "$c19e" $((MOCK_PORT_BASE + 914))
# fake engine hook: a watcher writes the mock directive the moment step a's log appears
( for _ in $(seq 1 200); do
    if [[ -f "$c19e/cr-scratch/test-brand/order-h1/logs/a.log" ]]; then printf 'cancel' > "$c19_ctl/directive"; break; fi
    sleep 0.1
  done ) &
c19e_w=$!
c19_worker "$c19e" $((MOCK_PORT_BASE + 914))
wait "$c19e_w" 2>/dev/null
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19e_ev="$(c19_events "$c19_ctl/reports.ndjson")"
if [[ "$c19e_ev" == *"attempt_cancelled"* && "$c19e_ev" != *"step_started:c"* ]]; then
  pass "harness: directive cancel → attempt_cancelled, step c never started"
else
  fail "harness: cancel" "events='$c19e_ev'"
fi
rm -rf "$c19e"

echo "--- 19f: server down ~3 s mid-run → after recovery every seq present once, in order"
c19f="$(mktemp -d)"; c19_setup "$c19f" $((MOCK_PORT_BASE + 915)) '{"broll":[{"url":"https://cfw-media.test/broll.mp4"}]}'
( for _ in $(seq 1 200); do
    if [[ -d "$c19f/cr-scratch/test-brand/order-h1/steps/b" ]]; then touch "$c19_ctl/down"; sleep 3; rm -f "$c19_ctl/down"; break; fi
    sleep 0.1
  done ) &
c19f_w=$!
c19_worker "$c19f" $((MOCK_PORT_BASE + 915)) CFW_RENDER_STEP_TIMEOUT_SEC=60
wait "$c19f_w" 2>/dev/null
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19f_ev="$(c19_events "$c19_ctl/reports.ndjson")"
c19f_gap="$(python3 -c '
import json, sys
s = [json.loads(l)["seq"] for l in open(sys.argv[1]) if l.strip()]
print("ok" if s == list(range(1, len(s) + 1)) else "bad:%s" % s)' "$c19_ctl/reports.ndjson" 2>/dev/null)"
if [[ "$c19f_ev" == *"attempt_completed:-" && "$c19f_gap" == "ok" ]]; then
  pass "harness: 503 window buffered to pending-reports.ndjson and replayed — seqs 1..N contiguous, in order"
else
  fail "harness: down window" "events='$c19f_ev' seqs=$c19f_gap; $(tail -3 "$c19f/worker.out")"
fi
rm -rf "$c19f"

echo "--- 19g: order without manifest → Director path unchanged"
c19g="$(mktemp -d)"; mkdir -p "$c19g/mockstate" "$c19g/skills" "$c19g/cr-scratch" "$c19g/cr-state"
order_fixture order-plain-1 brand-1 video > "$c19g/queue.json"
c19g_pid="$(start_mock "$c19g/queue.json" "$c19g/mockstate" $((MOCK_PORT_BASE + 916)))"
c19_worker "$c19g" $((MOCK_PORT_BASE + 916)) FAKE_DIRECTOR_MODE=happy
kill "$c19g_pid" 2>/dev/null; wait "$c19g_pid" 2>/dev/null
if grep -q '"tool": "complete_render_order"' "$c19g/mockstate/calls.jsonl" 2>/dev/null && grep -q '"tool": "append_render_event"' "$c19g/mockstate/calls.jsonl" 2>/dev/null; then
  pass "harness: order without manifest still runs the Director path (stage events + complete)"
else
  fail "harness: director path" "calls: $(cat "$c19g/mockstate/calls.jsonl" 2>/dev/null | head -5)"
fi
rm -rf "$c19g"

echo "--- 19h: no credential-looking env/paths leak into logs or reports"
c19h="$(mktemp -d)"; c19_setup "$c19h" $((MOCK_PORT_BASE + 917))
c19_worker "$c19h" $((MOCK_PORT_BASE + 917)) FAKE_TOKEN=sk-abc123 OPENAI_API_KEY=sk-abc123 CODEX_HOME="$HOME/.codex-fake-auth.json"
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
if ! grep -rq 'sk-abc123\|codex-fake-auth' "$c19h/cr-scratch" "$c19_ctl/reports.ndjson" "$c19h/worker.out" 2>/dev/null; then
  pass "harness: planted secret + fake credential path appear nowhere in ORDER_DIR, logs or reports"
else
  fail "harness: credential leak" "$(grep -rl 'sk-abc123\|codex-fake-auth' "$c19h/cr-scratch" "$c19_ctl/reports.ndjson" "$c19h/worker.out" 2>/dev/null)"
fi
rm -rf "$c19h"

echo "--- 19j: render_slides workdir gets brief.json from the order, without secrets"
c19j="$(mktemp -d)"
mkdir -p "$c19j/skills/p-carousel/steps" "$c19j/mockstate" "$c19j/control" "$c19j/cr-scratch" "$c19j/cr-state"
python3 -c '
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = {
    "recipe": "p-carousel",
    "recipeVersion": "9.9.9",
    "steps": [
        {"id": "outline", "runsOn": "computer", "weight": 20, "instructions": "steps/01-outline.md",
         "saves": [{"id": "outline", "kind": "json"}]},
        {"id": "render_slides", "runsOn": "computer", "weight": 80, "instructions": "steps/03-render-slides.md",
         "saves": [{"id": "cover", "kind": "image"}], "maxCheckRetries": 0,
         "checks": [{"id": "slide_dims"}]},
    ],
}
recipe = root / "skills" / "p-carousel"
(recipe / "manifest.json").write_text(json.dumps(manifest))
(recipe / "steps" / "01-outline.md").write_text("outline\n")
(recipe / "steps" / "03-render-slides.md").write_text("render\n")
token = "brief-must-not-copy-token"
brand_key = "brief-must-not-copy-brandkey"
option_key = "brief-must-not-copy-optionkey"
task = {
    "version": 1, "orderId": "order-brief-1",
    "brand": {
        "id": "brand-1", "slug": "test-brand", "name": "Test Brand", "brief": "brand brief text",
        "palette": {"bg": "#0F172A", "accent": "#F97316", "apiKey": brand_key},
        "typography": {"body": "Inter", "display": "Oswald"},
        "imageStyle": "editorial daylight", "apiKey": brand_key,
        "heygen": {"avatarId": "avatar-ok", "voiceId": "voice-ok", "accessToken": token},
        "elevenlabs": {"voiceId": "el-voice-ok", "apiKey": brand_key},
    },
    "kind": "image", "recipe": "p-carousel", "workspaceId": "ws-1",
    "intent": "listing open house", "ingredients": [], "targets": ["instagram", "linkedin"],
    "options": {"num_slides": 5, "apiKey": option_key},
    "credentials": {"heygen": {"accessToken": token, "mode": "oauth"}},
    "providerKeys": {"kie": brand_key},
}
order = {
    "id": "order-brief-1", "brandId": "brand-1", "brandName": "Test Brand", "workspaceId": "ws-1",
    "kind": "image", "recipe": "p-carousel", "recipeVersion": "9.9.9",
    "manifest": str(recipe / "manifest.json"), "inputs": {}, "status": "queued",
    "priority": 0, "attempts": 1, "taskOrder": task,
}
(root / "queue.json").write_text(json.dumps([order]))
' "$c19j"
c19_state="$c19j/mockstate"; c19_ctl="$c19j/control"
c19j_port=$((MOCK_PORT_BASE + 930))
c19_pid="$(CFW_MOCK_CONTROL_DIR="$c19_ctl" start_mock "$c19j/queue.json" "$c19_state" "$c19j_port")"
c19_worker "$c19j" "$c19j_port" FAKE_ENGINE_FAIL_STEP=render_slides FAKE_ENGINE_FAIL_CHECK_TIMES=1
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
c19j_ev="$(c19_events "$c19_ctl/reports.ndjson")"
if python3 -c '
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
order_dir = root / "cr-scratch" / "test-brand" / "order-brief-1"
needles = ("brief-must-not-copy-token", "brief-must-not-copy-brandkey", "brief-must-not-copy-optionkey")
problems = []
for step in ("outline", "render_slides"):
    path = order_dir / "steps" / step / "brief.json"
    if not path.is_file():
        problems.append(step + " brief.json missing")
        continue
    raw = path.read_text()
    if any(needle in raw for needle in needles):
        problems.append(step + " brief.json contains a planted secret")
    data = json.loads(raw)
    brand = data.get("brand") if isinstance(data.get("brand"), dict) else {}
    heygen = brand.get("heygen") if isinstance(brand.get("heygen"), dict) else {}
    eleven = brand.get("elevenlabs") if isinstance(brand.get("elevenlabs"), dict) else {}
    palette = brand.get("palette") if isinstance(brand.get("palette"), dict) else {}
    typography = brand.get("typography") if isinstance(brand.get("typography"), dict) else {}
    if data.get("recipe") != "p-carousel":
        problems.append(step + " recipe")
    if data.get("intent") != "listing open house":
        problems.append(step + " intent")
    if data.get("targets") != ["instagram", "linkedin"]:
        problems.append(step + " targets")
    if brand.get("slug") != "test-brand" or brand.get("name") != "Test Brand" or brand.get("brief") != "brand brief text":
        problems.append(step + " brand text")
    if palette.get("bg") != "#0F172A" or "apiKey" in palette:
        problems.append(step + " palette")
    if typography.get("body") != "Inter":
        problems.append(step + " typography")
    if brand.get("imageStyle") != "editorial daylight":
        problems.append(step + " imageStyle")
    if heygen.get("avatarId") != "avatar-ok" or heygen.get("voiceId") != "voice-ok" or "accessToken" in heygen:
        problems.append(step + " heygen ids")
    if eleven.get("voiceId") != "el-voice-ok" or "apiKey" in eleven:
        problems.append(step + " elevenlabs id")
    if data.get("options") != {"num_slides": 5}:
        problems.append(step + " options")
    for banned in ("credentials", "providerKeys", "apiKey", "accessToken"):
        if banned in data or banned in brand:
            problems.append(step + " banned " + banned)
if problems:
    sys.stderr.write("brief.json checks failed: " + ", ".join(problems) + "\n")
    sys.exit(1)
' "$c19j" && [[ "$c19j_ev" == *"step_started:render_slides"* ]]; then
  pass "harness: render_slides workdir brief.json has recipe=p-carousel and intent, and no secrets"
else
  fail "harness: render_slides brief.json" "events=$c19j_ev; $(tail -n 5 "$c19j/worker.out" 2>/dev/null)"
fi
rm -rf "$c19j"

echo "--- 19i: the five real batch-1 manifests (M2-06) — every computer step starts and completes against the mock"
# c19i_setup <dir> <port> <recipe> — like c19_setup but on a real skills/<recipe> (manifest + steps copied in),
# inputs {} (the fake engine writes every save; required-at-start inputs are not enforced by the harness),
# and a brand-scoped HeyGen OAuth credential on *-heygen orders so the CFW-313 gate lets the claim through.
c19i_setup() {
  local dir="$1" port="$2" recipe="$3" cred=""
  local man="$REPO_DIR/skills/$recipe/manifest.json"
  c19_state="$dir/mockstate"; c19_ctl="$dir/control"
  mkdir -p "$c19_state" "$c19_ctl" "$dir/skills/$recipe" "$dir/cr-scratch" "$dir/cr-state"
  cp "$man" "$dir/skills/$recipe/manifest.json"; cp -R "$REPO_DIR/skills/$recipe/steps" "$dir/skills/$recipe/steps"
  [[ "$recipe" == *-heygen ]] && cred='{"mode":"oauth","accessToken":"test-heygen-oauth-token-19i","expiresAt":"2099-01-01T00:00:00Z","creditPool":"plan_credits"}'
  python3 -c '
import json, sys
man, recipe, cred = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(man))
task = {"version": 1, "orderId": "order-19i", "brand": {"id": "brand-1", "slug": "test-brand", "brief": "b"},
        "kind": "video", "recipe": recipe, "workspaceId": "ws-1", "intent": "t", "ingredients": [], "targets": ["instagram"]}
if cred: task["credentials"] = {"heygen": json.loads(cred)}
print(json.dumps([{"id": "order-19i", "brandId": "brand-1", "workspaceId": "ws-1", "kind": "video",
  "recipe": recipe, "recipeVersion": m["recipeVersion"], "manifest": man, "inputs": {},
  "status": "queued", "priority": 0, "attempts": 1, "taskOrder": task}]))
' "$man" "$recipe" "$cred" > "$dir/queue.json"
  c19_pid="$(CFW_MOCK_CONTROL_DIR="$c19_ctl" start_mock "$dir/queue.json" "$c19_state" "$port")"
}
c19i_port=$((MOCK_PORT_BASE + 918))
for c19i_r in ${CFW_TEST_19I_RECIPES:-p-reels-pip p-reels-split p-reels-spotlight-heygen p-reels-pip-heygen p-reels-split-heygen}; do
  c19i="$(mktemp -d)"; c19i_setup "$c19i" "$c19i_port" "$c19i_r"
  c19_worker "$c19i" "$c19i_port"
  kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
  c19i_ev="$(c19_events "$c19_ctl/reports.ndjson")"
  c19i_want="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
# With inputs {} and no alternative chosen: always-steps run; a step gated on an
# optional input or an alternative is reported skipped; server steps never show.
def one(s):
    if s["runsOn"] != "computer": return ""
    if s.get("when", "always") == "always": return "step_started:%s step_completed:%s" % (s["id"], s["id"])
    return "step_skipped:%s" % s["id"]
print(" ".join(x for x in (one(s) for s in m["steps"]) if x) + " attempt_completed:-")
' "$REPO_DIR/skills/$c19i_r/manifest.json")"
  if [[ "$c19i_ev" == "$c19i_want" && "$(c19_seqs_ok "$c19_ctl/reports.ndjson")" == "ok" && "$(c19_completed "$c19i")" == "1" ]]; then
    pass "harness: $c19i_r — every computer step started+completed in manifest order, attempt_completed, complete_render_order ok"
  else
    fail "harness: $c19i_r" "events='$c19i_ev' want='$c19i_want' seqs=$(c19_seqs_ok "$c19_ctl/reports.ndjson") completed=$(c19_completed "$c19i"); worker.out: $(tail -n "${CFW_TEST_19I_TAIL:-5}" "$c19i/worker.out")"
  fi
  rm -rf "$c19i"; c19i_port=$((c19i_port + 1))
done

echo "=== Case 20a: check-step-files.py green — ok fixture PASSes, exit 0 (M1-09) ==="
c20_checker="$REPO_DIR/scripts/check-step-files.py"
c20_fixture="$TEST_DIR/fixtures/manifests/stepfiles-ok"
c20_skills="$(mktemp -d)"
cp -R "$c20_fixture" "$c20_skills/p-stepfiles-ok"
c20a_out="$(python3 "$c20_checker" --skills-dir "$c20_skills" 2>&1)"
c20a_rc=$?
if [[ "$c20a_rc" == "0" ]] && grep -q '^PASS' <<< "$c20a_out"; then
  pass "check-step-files.py: ok fixture → one-line PASS, exit 0"
else
  fail "check-step-files.py: ok fixture" "expected exit 0 + PASS line, got rc=$c20a_rc: $c20a_out"
fi

echo "=== Case 20b: check-step-files.py red — steps/_shared.md missing (M1-09) ==="
rm -f "$c20_skills/p-stepfiles-ok/steps/_shared.md"
c20b_out="$(python3 "$c20_checker" --skills-dir "$c20_skills" 2>&1)"
c20b_rc=$?
if [[ "$c20b_rc" == "1" ]] && grep -q 'steps/_shared.md:0: missing steps/_shared.md' <<< "$c20b_out"; then
  pass "check-step-files.py: exit 1 naming the missing steps/_shared.md"
else
  fail "check-step-files.py: missing _shared.md" "expected exit 1 naming _shared.md, got rc=$c20b_rc: $c20b_out"
fi
cp "$c20_fixture/steps/_shared.md" "$c20_skills/p-stepfiles-ok/steps/_shared.md"

echo "=== Case 20c: check-step-files.py red — planted /opt/cfw-agent/.env host path (M1-09) ==="
printf 'source /opt/cfw-agent/.env\n' >> "$c20_skills/p-stepfiles-ok/steps/01.md"
c20c_line="$(wc -l < "$c20_skills/p-stepfiles-ok/steps/01.md" | tr -d ' ')"
c20c_out="$(python3 "$c20_checker" --skills-dir "$c20_skills" 2>&1)"
c20c_rc=$?
if [[ "$c20c_rc" == "1" ]] && grep -q "steps/01.md:${c20c_line}: banned token '/opt/'" <<< "$c20c_out"; then
  pass "check-step-files.py: exit 1 with file:line for the planted /opt/ token (line $c20c_line)"
else
  fail "check-step-files.py: planted /opt/ path" "expected exit 1 + 01.md:$c20c_line, got rc=$c20c_rc: $c20c_out"
fi
cp "$c20_fixture/steps/01.md" "$c20_skills/p-stepfiles-ok/steps/01.md"

echo "=== Case 20d: check-step-files.py red — step file stops mentioning saves/x. (M1-09) ==="
sed -i.bak 's#saves/x\.json#saves/other.json#' "$c20_skills/p-stepfiles-ok/steps/01.md"
rm -f "$c20_skills/p-stepfiles-ok/steps/01.md.bak"
c20d_out="$(python3 "$c20_checker" --skills-dir "$c20_skills" 2>&1)"
c20d_rc=$?
if [[ "$c20d_rc" == "1" ]] && grep -q "steps\[one\] never mentions saves/x.<ext> for save 'x'" <<< "$c20d_out"; then
  pass "check-step-files.py: exit 1 naming the unmentioned save id 'x'"
else
  fail "check-step-files.py: missing saves/x. mention" "expected exit 1 naming save 'x', got rc=$c20d_rc: $c20d_out"
fi
rm -rf "$c20_skills"

echo "=== Case 20e: check-step-files.py on the committed skills/ bundle (M1-09) ==="
c20e_out="$(python3 "$c20_checker" --skills-dir "$REPO_DIR/skills" 2>&1)"
c20e_rc=$?
if [[ "$c20e_rc" == "0" ]] && grep -q '^PASS' <<< "$c20e_out"; then
  pass "check-step-files.py: real skills/ tree passes (Spotlight step files clean)"
else
  fail "check-step-files.py: real skills/ tree" "expected exit 0, got rc=$c20e_rc: $c20e_out"
fi

echo "=== Case 20f: check-no-host-paths.sh still green on the real tree after the Spotlight split (M1-09) ==="
if "$REPO_DIR/scripts/check-no-host-paths.sh" --skills-dir "$REPO_DIR/skills" >/dev/null 2>&1; then
  pass "check-no-host-paths.sh: real skills/ tree still PASSes after the Spotlight step split"
else
  fail "check-no-host-paths.sh after split" "expected exit 0 on the real skills/ tree"
fi

echo "=== Case 21a: cr_probe_engine_headless — codex-only PATH ==="
c21_tmp="$(mktemp -d)"
trap 'rm -rf "$c21_tmp"' EXIT
mkdir -p "$c21_tmp/codex-only" "$c21_tmp/claude-only" "$c21_tmp/silent" "$c21_tmp/empty"
printf '#!/bin/sh\necho "codex-cli 9.9.9"\n' > "$c21_tmp/codex-only/codex"
printf '#!/bin/sh\necho "1.2.3 (Claude Code)"\n' > "$c21_tmp/claude-only/claude"
printf '#!/bin/sh\nexit 0\n' > "$c21_tmp/silent/codex"
printf '#!/bin/sh\nexit 0\n' > "$c21_tmp/silent/claude"
chmod +x "$c21_tmp"/*/codex "$c21_tmp"/*/claude 2>/dev/null || true
c21_base="/usr/bin:/bin"
(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_engine_headless codex "$c21_tmp/codex-only:$c21_base"
) >/dev/null 2>&1
c21a_codex=$?
(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_probe_engine_headless claude "$c21_tmp/codex-only:$c21_base"
) >/dev/null 2>&1
c21a_claude=$?
if [[ "$c21a_codex" == "0" && "$c21a_claude" != "0" ]]; then
  pass "cr_probe_engine_headless: codex-only PATH → codex 0, claude non-zero"
else
  fail "cr_probe_engine_headless codex-only" "codex rc=$c21a_codex claude rc=$c21a_claude"
fi

echo "=== Case 21b: cr_probe_engine_headless — both missing / both silent ==="
c21b_fail=0
for e in codex claude; do
  for d in empty silent; do
    (
      # shellcheck source=/dev/null
      source "$REPO_DIR/bin/cfw-render-lib.sh"
      cr_probe_engine_headless "$e" "$c21_tmp/$d:$c21_base"
    ) >/dev/null 2>&1 && c21b_fail=1
  done
done
if [[ "$c21b_fail" == "0" ]]; then
  pass "cr_probe_engine_headless: both missing → both non-zero; exit-0-but-silent → non-zero"
else
  fail "cr_probe_engine_headless both missing" "a probe unexpectedly returned 0"
fi

echo "=== Case 21c: cr_install_select_engine — picks codex | claude-code | aborts naming both ==="
c21c_sel() { # c21c_sel <path>
  (
    # shellcheck source=/dev/null
    source "$REPO_DIR/bin/cfw-render-lib.sh"
    cr_install_select_engine "$1"
  ) 2>/dev/null
}
c21c_codex="$(c21c_sel "$c21_tmp/codex-only:$c21_base")" || true
c21c_claude="$(c21c_sel "$c21_tmp/claude-only:$c21_base")" || true
c21c_none_err="$(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_install_select_engine "$c21_tmp/empty:$c21_base" 2>&1 >/dev/null
)"
c21c_none_rc=$?
if [[ "$c21c_codex" == "codex" ]]; then
  pass "cr_install_select_engine: codex-only → codex"
else
  fail "cr_install_select_engine codex-only" "got '$c21c_codex'"
fi
if [[ "$c21c_claude" == "claude-code" ]]; then
  pass "cr_install_select_engine: claude-only → claude-code (the value cr_engine_detect accepts)"
else
  fail "cr_install_select_engine claude-only" "got '$c21c_claude'"
fi
if [[ "$c21c_none_rc" == "1" ]] && grep -q 'Codex' <<< "$c21c_none_err" && grep -q 'Claude Code' <<< "$c21c_none_err" && grep -q 'login' <<< "$c21c_none_err"; then
  pass "cr_install_select_engine: neither → rc 1, message names Codex, Claude Code, and login"
else
  fail "cr_install_select_engine neither" "rc=$c21c_none_rc msg: $c21c_none_err"
fi
c21c_pre="$(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  CFW_RENDER_ENGINE=claude-code cr_install_select_engine "$c21_tmp/codex-only:$c21_tmp/claude-only:$c21_base" 2>/dev/null
)" || true
if [[ "$c21c_pre" == "claude-code" ]]; then
  pass "cr_install_select_engine: preset CFW_RENDER_ENGINE=claude-code honoured when it passes"
else
  fail "cr_install_select_engine preset" "got '$c21c_pre'"
fi

echo "=== Case 21d: credentials are never read — marker never surfaces; lib never names the files ==="
c21d_home="$(mktemp -d)"
mkdir -p "$c21d_home/.codex" "$c21d_home/.claude"
c21d_marker="CFW_SECRET_MARKER_$$_DO_NOT_LEAK"
printf '{"token":"%s"}\n' "$c21d_marker" > "$c21d_home/.codex/auth.json"
printf '{"token":"%s"}\n' "$c21d_marker" > "$c21d_home/.claude/.credentials.json"
c21d_out="$(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  HOME="$c21d_home" cr_install_select_engine "$c21_tmp/codex-only:$c21_tmp/claude-only:$c21_base" 2>&1
  HOME="$c21d_home" cr_install_select_engine "$c21_tmp/empty:$c21_base" 2>&1 || true
)"
if ! grep -q "$c21d_marker" <<< "$c21d_out"; then
  pass "credentials: marker planted in ~/.codex/auth.json + ~/.claude/.credentials.json never appears in output"
else
  fail "credentials leak" "marker surfaced in: $c21d_out"
fi
c21d_body="$(awk '/^cr_(install_select_engine|probe_engine_headless)\(\) \{/{p=1} p{print} p&&/^}/{p=0}' "$REPO_DIR/bin/cfw-render-lib.sh")"
if [[ -n "$c21d_body" ]] && ! grep -qiE 'auth\.json|\.credentials|credentials\.json|\.codex/|\.claude/' <<< "$c21d_body"; then
  pass "credentials: cr_install_select_engine + cr_probe_engine_headless bodies reference no auth.json / credentials / vendor dot-dirs"
else
  fail "credentials grep" "engine-selection function bodies mention a credential file (or body not found)"
fi
rm -rf "$c21d_home"
# ===========================================================================
# M2-04: capacity, parallel claims, stop_after_step, resume, kept-alive loop
# ===========================================================================
# c21_setup <dir> <port> <manifest-name> <orders-json> [mock env...] — seeds N
# manifest orders (orders-json is a list of {id, urgent?}), starts the mock.
c21_setup() {
  local dir="$1" port="$2" mname="$3" orders="$4"; shift 4
  c21_state="$dir/mockstate"; c21_ctl="$dir/control"
  mkdir -p "$c21_state" "$c21_ctl" "$dir/skills/$mname" "$dir/cr-scratch" "$dir/cr-state"
  cp "$REPO_DIR/test/fixtures/manifests/$mname/manifest.json" "$dir/skills/$mname/manifest.json"
  python3 -c '
import json, sys
mpath, mname, specs = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
out = []
for sp in specs:
    out.append({"id": sp["id"], "brandId": "brand-1", "workspaceId": "ws-1", "kind": "video",
      "recipe": mname, "recipeVersion": "1.0.0", "manifest": mpath, "inputs": {}, "urgent": bool(sp.get("urgent")),
      "status": "queued", "priority": 0, "attempts": 1,
      "taskOrder": {"version": 1, "orderId": sp["id"], "brand": {"id": "brand-1", "slug": "test-brand", "brief": "b"},
                    "kind": "video", "recipe": mname, "workspaceId": "ws-1", "intent": "t", "ingredients": [], "targets": ["instagram"]}})
print(json.dumps(out))' "$dir/skills/$mname/manifest.json" "$mname" "$orders" > "$dir/queue.json"
  # Extra KEY=VALUE args become env for the mock. A subshell keeps them off
  # this shell; the function call stays in-process (functions are not
  # exported, so `bash -c` would not see start_mock).
  c21_pid="$(
    export CFW_MOCK_CONTROL_DIR="$c21_ctl"
    for kv in "$@"; do export "${kv?}"; done
    start_mock "$dir/queue.json" "$c21_state" "$port"
  )"
}
export -f start_mock
# c21_worker <dir> <port> <mode: --once|--loop> [env assignments...]
c21_worker() {
  local dir="$1" port="$2" mode="$3"; shift 3
  (
    export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
    export CFW_API_BASE="http://127.0.0.1:$port"
    export CFW_RENDER_TEST_MEDIA_BASE_URL="$CFW_API_BASE"
    export CFW_RENDER_WORKER_KEY="cfw_render_test0000000000000000"
    export CFW_RENDER_ENV="/nonexistent-cfw-render-env-for-tests"
    export CFW_RENDER_STATE_DIR="$dir/cr-state"
    export CFW_RENDER_LOG_DIR="$dir/cr-state" CFW_RENDER_KEEP_OUTPUTS=0
    export CFW_RENDER_SCRATCH="$dir/cr-scratch"
    export CFW_RENDER_SKILLS_DIR="$dir/skills"
    export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
    export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
    export CFW_RENDER_ENGINE_CMD="$TEST_DIR/fake-engine.sh"
    export CFW_RENDER_HEARTBEAT_SEC=1
    export CFW_RENDER_CONCURRENCY=1
    export CFW_WORKER_ID="w-m2"
    export CFW_RENDER_UPLOAD_MODE=multipart
    # Pin the load-average seam: a busy dev box (load > ncpu) otherwise makes
    # every normal claim skip and the M2-04 cases flake on host load.
    export CFW_RENDER_CAPACITY_LOAD=0
    export CFW_RENDER_SECURITY_CMD=/usr/bin/false   # [M3-08b] no Keychain keys unless a case adds a stub
    for kv in "$@"; do export "${kv?}"; done
    "$REPO_DIR/bin/cfw-render.sh" "$mode" > "$dir/worker.out" 2>&1
  )
}
# c21_claims <dir> — "running/max" per claim call, space-separated, in order
c21_claims() { python3 -c '
import json, sys
out = []
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["tool"] != "claim_render_order": continue
    c = d["args"].get("capacity")
    out.append("%s/%s" % (c["running"], c["max"]) if isinstance(c, dict) else "none")
print(" ".join(out))' "$1/mockstate/calls.jsonl" 2>/dev/null; }
c21_events_for() { python3 -c '
import json, sys
print(" ".join("%s:%s" % (d["event"], d.get("stepId") or "-") for d in (json.loads(l) for l in open(sys.argv[1]) if l.strip()) if d["event"] != "heartbeat" and d["orderId"] == sys.argv[2]))' "$1" "$2" 2>/dev/null; }

echo "=== Case 22: capacity table via seams — 32 GB / 8 perf cores → 4; 8 GB → 1 and the setup line (M2-04, D52/D78) ==="
c21a_max="$(CFW_RENDER_CONCURRENCY='' CFW_RENDER_CAPACITY_MEM_BYTES=$((32*1024*1024*1024)) CFW_RENDER_CAPACITY_PERF_CORES=8 bash -c 'source "$1/bin/cfw-render-lib.sh"; cr_capacity_max' _ "$REPO_DIR")"
c21b_max="$(CFW_RENDER_CONCURRENCY='' CFW_RENDER_CAPACITY_MEM_BYTES=$((8*1024*1024*1024)) CFW_RENDER_CAPACITY_PERF_CORES=4 bash -c 'source "$1/bin/cfw-render-lib.sh"; cr_capacity_max' _ "$REPO_DIR")"
c21b_note="$(CFW_RENDER_CONCURRENCY='' CFW_RENDER_CAPACITY_MEM_BYTES=$((8*1024*1024*1024)) CFW_RENDER_CAPACITY_PERF_CORES=4 bash -c 'source "$1/bin/cfw-render-lib.sh"; cr_capacity_setup_note' _ "$REPO_DIR")"
c21c_max="$(CFW_RENDER_CONCURRENCY='' CFW_RENDER_CAPACITY_MEM_BYTES=$((32*1024*1024*1024)) CFW_RENDER_CAPACITY_PERF_CORES=4 bash -c 'source "$1/bin/cfw-render-lib.sh"; cr_capacity_max' _ "$REPO_DIR")"
if [[ "$c21a_max" == "4" && "$c21b_max" == "1" && "$c21c_max" == "2" ]]; then
  pass "capacity table: 32GB/8 cores → 4; 8GB → 1; 32GB/4 cores → 2 (cores ÷ 2 cap)"
else
  fail "capacity table" "32GB/8c=$c21a_max (want 4) 8GB=$c21b_max (want 1) 32GB/4c=$c21c_max (want 2)"
fi
if [[ "$c21b_note" == "This computer runs one request at a time. It still serves your brands; bigger jobs just take turns." ]]; then
  pass "capacity: max 1 → setup summary says 'This computer runs one request at a time…' (D78)"
else
  fail "capacity setup line" "got: $c21b_note"
fi
if grep -q 'install.sh: \$(cr_capacity_setup_note)' "$REPO_DIR/install/install.sh"; then
  pass "install.sh prints the capacity setup note"
else
  fail "install.sh capacity note" "install.sh does not call cr_capacity_setup_note"
fi

echo "=== Case 23: 3 running + a normal 4th queued → no 4th claim; urgent 4th → claimed alongside (M2-04, D51) ==="
c22a="$(mktemp -d)"
c21_setup "$c22a" $((MOCK_PORT_BASE + 920)) harness-3step '[{"id":"o1"},{"id":"o2"},{"id":"o3"},{"id":"o4"}]' CFW_MOCK_ORDERS_ARRAY=1
c21_worker "$c22a" $((MOCK_PORT_BASE + 920)) --once CFW_RENDER_CONCURRENCY=3
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c22a_claims="$(c21_claims "$c22a")"
c22a_done="$(grep -c '"tool": "complete_render_order".*"ok": true' "$c22a/mockstate/calls.jsonl" 2>/dev/null || true)"
c22a_o4="$(grep -c '"orderId": "o4"' "$c21_ctl/reports.ndjson" 2>/dev/null || true)"
if [[ "$c22a_claims" == "0/3 3/3" && "$c22a_done" == "3" && "$c22a_o4" == "0" ]]; then
  pass "capacity: orders[] claim 0/3 took three; the full ask (3/3) returned nothing for a normal o4; 3 completed"
else
  fail "capacity: 3 running + normal" "claims='$c22a_claims' (want '0/3 3/3') done=$c22a_done o4-reports=$c22a_o4; $(tail -3 "$c22a/worker.out")"
fi
rm -rf "$c22a"
c22b="$(mktemp -d)"
c21_setup "$c22b" $((MOCK_PORT_BASE + 921)) harness-3step '[{"id":"o1"},{"id":"o2"},{"id":"o3"},{"id":"o4","urgent":true}]' CFW_MOCK_ORDERS_ARRAY=1
c21_worker "$c22b" $((MOCK_PORT_BASE + 921)) --once CFW_RENDER_CONCURRENCY=3
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c22b_claims="$(c21_claims "$c22b")"
c22b_done="$(grep -c '"tool": "complete_render_order".*"ok": true' "$c22b/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$c22b_claims" == "0/3 3/3" && "$c22b_done" == "4" ]] && grep -q "urgent ask with running=3 max=3 returned 1 order" "$c22b/cr-state/cfw-render.log"; then
  pass "capacity: full ask (3/3) returned the urgent o4 → started alongside; 4 completed"
else
  fail "capacity: 3 running + urgent" "claims='$c22b_claims' done=$c22b_done; log: $(grep -i 'capacity\|urgent' "$c22b/cr-state/cfw-render.log" | tail -3)"
fi
rm -rf "$c22b"

echo "=== Case 24: free memory under the floor → no normal claim; urgent-only ask only once the server has shown it honours capacity (M2-04) ==="
# 23a: fresh process, floor breached, server never answered yet → no ask at all
# (an old server would hand a normal order to a starved computer).
c23="$(mktemp -d)"
c21_setup "$c23" $((MOCK_PORT_BASE + 922)) harness-3step '[{"id":"o1"}]' CFW_MOCK_ORDERS_ARRAY=1
c21_worker "$c23" $((MOCK_PORT_BASE + 922)) --once CFW_RENDER_CONCURRENCY=2 CFW_RENDER_CAPACITY_FREE_MB=1000
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c23_claims="$(c21_claims "$c23")"
c23_done="$(grep -c '"tool": "complete_render_order"' "$c23/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$c23_claims" == "" && "$c23_done" == "0" ]] && grep -q "normal claims skipped, urgent only" "$c23/cr-state/cfw-render.log"; then
  pass "capacity: free 1000 MB < 3072 floor on a fresh process → no claim at all (server not yet known to honour capacity), o1 left queued, logged"
else
  fail "capacity: floor (fresh)" "claims='$c23_claims' (want '') done=$c23_done; log: $(grep capacity "$c23/cr-state/cfw-render.log" | tail -2)"
fi
rm -rf "$c23"
# 23b: --loop with the floor breached from the 2nd round on: round 1 claims
# normally (teaches the worker the server honours capacity), later rounds
# make only the full ask (2/2) and o2 stays queued.
c23b="$(mktemp -d)"
c21_setup "$c23b" $((MOCK_PORT_BASE + 923)) harness-3step '[{"id":"o1"},{"id":"o2"}]' CFW_MOCK_ORDERS_ARRAY=1 CFW_MOCK_MAX_PER_CLAIM=1
c23b_floor="$c23b/floor"; : > "$c23b_floor"
c21_worker "$c23b" $((MOCK_PORT_BASE + 923)) --loop CFW_RENDER_CONCURRENCY=2 CFW_RENDER_CAPACITY_UNIT_SECS=0.05 CFW_RENDER_CAPACITY_FREE_MB_FILE="$c23b_floor" &
c23b_w=$!
for _ in $(seq 1 100); do grep -q '"tool": "claim_render_order"' "$c23b/mockstate/calls.jsonl" 2>/dev/null && break; sleep 0.1; done
printf '1000' > "$c23b_floor"
sleep 3
stop_test_tree "$c23b_w" || { fail "loop cleanup" "could not stop owned tree"; exit 1; }
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c23b_claims="$(c21_claims "$c23b")"
# Round 1 fills the computer one order per reply (0/2, 1/2, then the full
# ask 2/2); once the floor is breached every later ask is the full one.
c23b_tail="$(sed -E 's/^0\/2 1\/2 2\/2 ?//' <<< "$c23b_claims")"
if [[ "$c23b_claims" == 0/2\ 1/2\ 2/2* && "$(tr ' ' '\n' <<< "$c23b_tail" | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//')" == "2/2" ]] && grep -q "normal claims skipped, urgent only" "$c23b/cr-state/cfw-render.log"; then
  pass "capacity: floor breached after round 1 → only full asks (2/2) afterwards; logged"
else
  fail "capacity: floor (loop)" "claims='$c23b_claims' (want '0/2 1/2 2/2' then only '2/2'); log: $(grep capacity "$c23b/cr-state/cfw-render.log" | tail -3)"
fi
rm -rf "$c23b"

echo "=== Case 25: stop_after_step → step finishes, uploads, attempt_released revoked, folder gone (M2-04, D76) ==="
c24="$(mktemp -d)"
c21_setup "$c24" $((MOCK_PORT_BASE + 923)) harness-3step '[{"id":"o1"}]' CFW_MOCK_STOP_AFTER_STEP=1
c21_worker "$c24" $((MOCK_PORT_BASE + 923)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c24_ev="$(c21_events_for "$c21_ctl/reports.ndjson" o1)"
c24_rel="$(python3 -c '
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["event"] == "attempt_released": print(d.get("stepId"), d.get("reason"))' "$c21_ctl/reports.ndjson" 2>/dev/null)"
c24_up="$(python3 -c '
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["event"] == "step_completed" and d.get("stepId") == "a": print(len(d.get("outputs") or []))' "$c21_ctl/reports.ndjson" 2>/dev/null)"
if [[ "$c24_ev" == "step_started:a step_completed:a attempt_released:a" && "$c24_rel" == "a revoked" && "$c24_up" == "1" && ! -d "$c24/cr-scratch/test-brand/order-o1" ]]; then
  pass "stop_after_step: a completed with its upload, attempt_released {stepId:a, reason:revoked}, no step c, order folder deleted"
else
  fail "stop_after_step" "events='$c24_ev' released='$c24_rel' uploads=$c24_up dir-exists=$([[ -d "$c24/cr-scratch/test-brand/order-o1" ]] && echo yes || echo no); $(tail -3 "$c24/worker.out")"
fi
rm -rf "$c24"

echo "=== Case 26: resume with two saved outputs → a, b skipped; starts at plan_broll (M2-04, D30) ==="
c25="$(mktemp -d)"
c21_setup "$c25" $((MOCK_PORT_BASE + 924)) harness-resume '[{"id":"o1"}]' CFW_MOCK_RESUME_FROM=plan_broll
c21_worker "$c25" $((MOCK_PORT_BASE + 924)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c25_ev="$(c21_events_for "$c21_ctl/reports.ndjson" o1)"
c25_done="$(grep -c '"tool": "complete_render_order".*"ok": true' "$c25/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$c25_ev" == "step_started:plan_broll step_completed:plan_broll step_started:c step_completed:c attempt_completed:-" && "$c25_done" == "1" ]] && grep -q "resumes at plan_broll (2 saved output(s) restored)" "$c25/cr-state/cfw-render.log"; then
  pass "resume: savedOutputs a/x + b/y restored, a and b never run, plan_broll → c → attempt_completed"
else
  fail "resume" "events='$c25_ev' done=$c25_done; log: $(grep -i 'resum' "$c25/cr-state/cfw-render.log" | tail -2)"
fi
rm -rf "$c25"

echo "=== Case 27: a saved output 404s → step_failed 'Saved result from step a is missing' + attempt_failed (M2-04) ==="
c26="$(mktemp -d)"
c21_setup "$c26" $((MOCK_PORT_BASE + 925)) harness-resume '[{"id":"o1"}]' CFW_MOCK_RESUME_FROM=plan_broll CFW_MOCK_RESUME_404=a/x
c21_worker "$c26" $((MOCK_PORT_BASE + 925)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c26_ev="$(c21_events_for "$c21_ctl/reports.ndjson" o1)"
c26_err="$(python3 -c '
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["event"] == "step_failed": print(d.get("stepId"), "|", d.get("error") or d.get("reason") or d.get("message") or json.dumps(d))' "$c21_ctl/reports.ndjson" 2>/dev/null)"
if [[ "$c26_ev" == *"step_failed:"* && "$c26_ev" == *"attempt_failed:"* && "$c26_ev" != *"step_completed"* && "$c26_err" == *"Saved result from step a is missing"* ]]; then
  pass "resume: a/x 404 → step_failed 'Saved result from step a is missing', attempt_failed, nothing completed"
else
  fail "resume 404" "events='$c26_ev' err='$c26_err'; $(tail -3 "$c26/worker.out")"
fi
rm -rf "$c26"

echo "=== Case 28: old server ignores capacity → M1 behaviour, one order per claim, still fills max (M2-04) ==="
c27="$(mktemp -d)"
c21_setup "$c27" $((MOCK_PORT_BASE + 926)) harness-3step '[{"id":"o1"},{"id":"o2"},{"id":"o3"}]' CFW_MOCK_IGNORE_CAPACITY=1
c21_worker "$c27" $((MOCK_PORT_BASE + 926)) --once CFW_RENDER_CONCURRENCY=2
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c27_claims="$(c21_claims "$c27")"
c27_done="$(grep -c '"tool": "complete_render_order".*"ok": true' "$c27/mockstate/calls.jsonl" 2>/dev/null || true)"
c27_orders="$(python3 -c '
import json, sys
print(" ".join(sorted({json.loads(l)["orderId"] for l in open(sys.argv[1]) if l.strip()})))' "$c21_ctl/reports.ndjson" 2>/dev/null)"
# No full ask (2/2) against a server that never answered with orders[]: it
# ignores capacity and would hand a normal o3 to a full computer.
if [[ "$c27_claims" == "0/2 1/2" && "$c27_done" == "2" && "$c27_orders" == "o1 o2" ]]; then
  pass "old server: capacity sent on every claim (0/2 1/2) but ignored → single order per reply; no full ask; 2 ran, o3 stayed queued"
else
  fail "old server" "claims='$c27_claims' (want '0/2 1/2') done=$c27_done orders='$c27_orders'"
fi
rm -rf "$c27"

echo "=== Case 29: --loop claim back-off grows 1u→2u→4u→8u→10u with ONE log line per step (M2-04, D89) ==="
c28="$(mktemp -d)"
c21_setup "$c28" $((MOCK_PORT_BASE + 927)) harness-3step '[{"id":"o1"}]' CFW_MOCK_CLAIM_ERROR=1
c21_worker "$c28" $((MOCK_PORT_BASE + 927)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=0.05 &
c28_w=$!
# every failed claim costs cr_mcp_call's own curl retries before the back-off
# sleep, so reaching the 10u cap line takes a while: wait for it, bounded.
# ...then at least one more failed claim at the cap, so tries > log lines
# proves the cap step was not logged again.
for _ in $(seq 1 60); do grep -q 'retrying every 0.5s' "$c28/cr-state/cfw-render.log" 2>/dev/null && break; sleep 0.5; done
c28_at_cap="$(grep -c '"tool": "claim_render_order"' "$c28/mockstate/calls.jsonl" 2>/dev/null || true)"
for _ in $(seq 1 40); do [[ "$(grep -c '"tool": "claim_render_order"' "$c28/mockstate/calls.jsonl" 2>/dev/null || true)" -gt "$c28_at_cap" ]] && break; sleep 0.5; done
# the loop runs cfw-render.sh under a subshell; stop the whole tree
stop_test_tree "$c28_w" || { fail "loop cleanup" "could not stop owned tree"; exit 1; }
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c28_steps="$(grep 'claim back-off: claim_render_order keeps failing' "$c28/cr-state/cfw-render.log" | sed -E 's/.*retrying every ([0-9.]+)s.*/\1/' | tr '\n' ' ' | sed 's/ $//')"
c28_tries="$(grep -c '"tool": "claim_render_order"' "$c28/mockstate/calls.jsonl" 2>/dev/null || true)"
c28_lines="$(grep -c 'claim back-off: claim_render_order keeps failing' "$c28/cr-state/cfw-render.log" 2>/dev/null || true)"
if [[ "$c28_steps" == "0.05 0.1 0.2 0.4 0.5" && "$c28_tries" -gt "$c28_lines" ]]; then
  pass "back-off: steps logged once each (0.05 0.1 0.2 0.4 0.5 = base→×2→cap 10u); $c28_tries failed claims, $c28_lines lines"
else
  fail "back-off" "steps='$c28_steps' (want '0.05 0.1 0.2 0.4 0.5') tries=$c28_tries lines=$c28_lines; $(tail -3 "$c28/cr-state/cfw-render.log")"
fi
if grep -q "pid=" "$c28/cr-state/tick.lock/info" 2>/dev/null || grep -q "loop: started" "$c28/cr-state/cfw-render.log"; then
  pass "loop: started under the tick lock (touched each round)"
else
  fail "loop start" "no 'loop: started' line: $(head -3 "$c28/cr-state/cfw-render.log")"
fi
rm -rf "$c28"

echo "=== Case 30: resume — saved output 404 → step_failed lands on the step that needs it (plan_broll), with the reason; worker exits cleanly (M2-04) ==="
c30="$(mktemp -d)"
c21_setup "$c30" $((MOCK_PORT_BASE + 928)) harness-resume '[{"id":"o1"}]' CFW_MOCK_RESUME_FROM=plan_broll CFW_MOCK_RESUME_404=a/x
c21_worker "$c30" $((MOCK_PORT_BASE + 928)) --once && c30_rc=0 || c30_rc=$?
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c30_fail="$(python3 -c '
import json, sys
for l in open(sys.argv[1]):
    d = json.loads(l)
    if d["event"] == "step_failed": print(d.get("stepId"), "|", d.get("message"))' "$c21_ctl/reports.ndjson" 2>/dev/null)"
c30_blocked="$(grep -c '"tool": "block_render_order"\|"tool": "release_render_order"\|"tool": "complete_render_order"' "$c30/mockstate/calls.jsonl" 2>/dev/null || true)"
c30_done="$(grep -c '"tool": "complete_render_order".*"ok": true' "$c30/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$c30_rc" == "0" && "$c30_fail" == "plan_broll | Saved result from step a is missing" && "$c30_done" == "0" ]] && ! grep -qiE 'unbound variable|syntax error|Traceback' "$c30/worker.out"; then
  pass "resume 404: exactly one step_failed {stepId: plan_broll, message: 'Saved result from step a is missing'}; worker exit 0, no crash, no completion (terminal calls=$c30_blocked)"
else
  fail "resume 404 (step + reason)" "rc=$c30_rc step_failed='$c30_fail' done=$c30_done; $(tail -3 "$c30/worker.out")"
fi
rm -rf "$c30"

echo "=== Case 31: old server (single \`order\`, no \`orders[]\`) at max 1 with an urgent order queued → exactly one claim, one order, no urgent re-ask (M2-04, M1 parity) ==="
c31="$(mktemp -d)"
c21_setup "$c31" $((MOCK_PORT_BASE + 929)) harness-3step '[{"id":"o1"},{"id":"o2","urgent":true}]' CFW_MOCK_IGNORE_CAPACITY=1
c21_worker "$c31" $((MOCK_PORT_BASE + 929)) --once CFW_RENDER_CONCURRENCY=1
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c31_claims="$(c21_claims "$c31")"
c31_done="$(grep -c '"tool": "complete_render_order".*"ok": true' "$c31/mockstate/calls.jsonl" 2>/dev/null || true)"
c31_orders="$(python3 -c '
import json, sys
print(" ".join(sorted({json.loads(l)["orderId"] for l in open(sys.argv[1]) if l.strip()})))' "$c21_ctl/reports.ndjson" 2>/dev/null)"
if [[ "$c31_claims" == "0/1" && "$c31_done" == "1" && "$c31_orders" == "o1" ]] && ! grep -q "urgent ask" "$c31/cr-state/cfw-render.log"; then
  pass "old server, max 1: one claim (0/1), one order (o1) run to completion, no urgent re-ask while full"
else
  fail "old server max 1" "claims='$c31_claims' (want '0/1') done=$c31_done orders='$c31_orders'; $(grep -i urgent "$c31/cr-state/cfw-render.log" | tail -2)"
fi
rm -rf "$c31"

# c3x_install <home> — runs install/install.sh --mode byoa into a throwaway
# HOME with launchctl disabled (never loads a real job, never touches the
# real ~/Library/LaunchAgents). Plist lands at <home>/Library/LaunchAgents.
c3x_install() {
  local home="$1" prefix env
  prefix="$home/prefix"; env="$home/test.env"; mkdir -p "$prefix"
  cat > "$env" <<EOF2
CFW_API_BASE=http://127.0.0.1:1
CFW_RENDER_WORKER_KEY=[REDACTED]
CFW_RENDER_STATE_DIR=$home/cfw-render-state
CFW_RENDER_SCRATCH=$home/cfw-render-scratch
EOF2
  (
    export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/Library/Caches/ms-playwright}"
    export HOME="$home"
    export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
    export CFW_RENDER_INSTALL_NO_LAUNCHCTL=1
    export CFW_RENDER_TEST_OS=Darwin
    "$REPO_DIR/install/install.sh" --mode byoa --prefix "$prefix" --env-file "$env" >"$home/install.log" 2>&1
  )
}
# c3x_plist <plist> <python expr over d> — plistlib-parsed value
c3x_plist() { python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }

echo "=== Case 32: idle computer claims within ~60 s — default idle cadence <= 60 s, plist runs the --loop (no schedule > 60 s), idle loop keeps re-claiming (M2-04, D89) ==="
c32_idle="$(env -u CFW_RENDER_CAPACITY_UNIT_SECS bash -c 'source "$1/bin/cfw-render-lib.sh"; echo "$CR_CAPACITY_IDLE_CLAIM_SECS"' _ "$REPO_DIR")"
if awk -v s="$c32_idle" 'BEGIN { exit !(s > 0 && s <= 60) }'; then
  pass "idle claim cadence default = ${c32_idle}s (<= 60)"
else
  fail "idle claim cadence" "CR_CAPACITY_IDLE_CLAIM_SECS='$c32_idle' (want 0 < s <= 60)"
fi
c32_home="$(mktemp -d)"
c3x_install "$c32_home"
c32_plist="$c32_home/Library/LaunchAgents/com.cfw.render.plist"
c32_shape="$(c3x_plist "$c32_plist" '(d["ProgramArguments"][1:], "StartCalendarInterval" in d, d.get("StartInterval", 0) <= 60, d.get("RunAtLoad"))')"
if [[ "$c32_shape" == "(['--loop'], False, True, True)" ]]; then
  pass "generated plist: ProgramArguments --loop, RunAtLoad, no StartCalendarInterval, no StartInterval > 60"
else
  fail "plist cadence" "got '$c32_shape'; install.log: $(tail -3 "$c32_home/install.log" 2>/dev/null)"
fi
rm -rf "$c32_home"
c32="$(mktemp -d)"
c21_setup "$c32" $((MOCK_PORT_BASE + 930)) harness-3step '[]' CFW_MOCK_ORDERS_ARRAY=1
c21_worker "$c32" $((MOCK_PORT_BASE + 930)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=0.2 &
c32_w=$!
for _ in $(seq 1 60); do [[ "$(grep -c '"tool": "claim_render_order"' "$c32/mockstate/calls.jsonl" 2>/dev/null || true)" -ge 3 ]] && break; sleep 0.1; done
stop_test_tree "$c32_w" || { fail "loop cleanup" "could not stop owned tree"; exit 1; }
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
c32_n="$(grep -c '"tool": "claim_render_order"' "$c32/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$c32_n" -ge 3 ]]; then
  pass "idle --loop re-claims every idle unit ($c32_n claims within ~6 s at unit 0.2 s)"
else
  fail "idle loop re-claim" "claims=$c32_n (want >= 3); $(tail -3 "$c32/cr-state/cfw-render.log" 2>/dev/null)"
fi
rm -rf "$c32"

echo "=== Case 33: generated plist is kept alive — KeepAlive true + ThrottleInterval > 0 (restart on kill, throttled) (M2-04, D89) ==="
c33_home="$(mktemp -d)"
c3x_install "$c33_home"
c33_ka="$(c3x_plist "$c33_home/Library/LaunchAgents/com.cfw.render.plist" '(d.get("KeepAlive") is True, isinstance(d.get("ThrottleInterval"), int) and d["ThrottleInterval"] > 0)')"
if [[ "$c33_ka" == "(True, True)" ]]; then
  pass "generated plist: KeepAlive=true, ThrottleInterval=$(c3x_plist "$c33_home/Library/LaunchAgents/com.cfw.render.plist" 'd["ThrottleInterval"]')"
else
  fail "plist KeepAlive/Throttle" "got '$c33_ka'; install.log: $(tail -3 "$c33_home/install.log" 2>/dev/null)"
fi
rm -rf "$c33_home"

echo "=== Case 34: claim back-off production defaults — base 60 s, cap 600 s (the 10-minute cap Case 29 reaches in test units) (M2-04, D89) ==="
c34="$(env -u CFW_RENDER_CAPACITY_UNIT_SECS bash -c 'source "$1/bin/cfw-render-lib.sh"; echo "$CR_CLAIM_BACKOFF_BASE_SECS $CR_CLAIM_BACKOFF_MAX_SECS"' _ "$REPO_DIR")"
if [[ "$c34" == "60 600" ]]; then
  pass "back-off defaults: base 60 s → cap 600 s"
else
  fail "back-off defaults" "got '$c34' (want '60 600')"
fi

echo "=== Case 35: re-running install over an old-schedule (--once + StartCalendarInterval) plist rewrites it to the kept-alive loop (M2-04, D89) ==="
c35_home="$(mktemp -d)"
mkdir -p "$c35_home/Library/LaunchAgents"
c35_plist="$c35_home/Library/LaunchAgents/com.cfw.render.plist"
python3 -c '
import plistlib, sys
plistlib.dump({"Label": "com.cfw.render", "ProgramArguments": ["/old/bin/cfw-render.sh", "--once"],
  "StartCalendarInterval": [{"Minute": m} for m in (5, 20, 35, 50)], "RunAtLoad": True}, open(sys.argv[1], "wb"))' "$c35_plist"
c3x_install "$c35_home"
c35_shape="$(c3x_plist "$c35_plist" '(d["ProgramArguments"][1:], "StartCalendarInterval" in d, d.get("KeepAlive"), d.get("ThrottleInterval", 0) > 0)')"
if [[ "$c35_shape" == "(['--loop'], False, True, True)" ]] && grep -q 'launchctl bootout.*launchctl bootstrap' "$c35_home/install.log"; then
  pass "old-schedule plist rewritten: --loop, no StartCalendarInterval, KeepAlive + ThrottleInterval; reload (bootout → bootstrap) surfaced"
else
  fail "old plist rewrite" "got '$c35_shape'; install.log: $(tail -3 "$c35_home/install.log" 2>/dev/null)"
fi
rm -rf "$c35_home"


# ---------------------------------------------------------------------------
# M3-01a: pause / battery / run-now / version / updateRequired
# ---------------------------------------------------------------------------
FAKE_CAFFEINATE_LOG="$(mktemp)"; export FAKE_CAFFEINATE_LOG
cat > "$FAKE_BIN/caffeinate" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_CAFFEINATE_LOG:-/dev/null}"
# Mirror caffeinate -w: exit when this specific worker exits, not after an
# arbitrary sleep requiring a host-wide cleanup. Never invoke real caffeinate.
exec python3 - "$3" <<'PY'
import os, sys, time
pid = int(sys.argv[1])
for _ in range(300):
    try: os.kill(pid, 0)
    except ProcessLookupError: break
    time.sleep(.1)
PY
EOF2
chmod +x "$FAKE_BIN/caffeinate"
# m3_tool_count <dir> <tool>
m3_tool_count() { grep -c "\"tool\": \"$2\"" "$1/mockstate/calls.jsonl" 2>/dev/null || true; }
# m3_status <dir> <python expr over d>
m3_status() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1/cr-state/status.json" "$2" 2>/dev/null; }

echo "=== Case M3-01a-1: paused file → no claim, set_computer_paused(owner) once, status.json paused ==="
m1="$(mktemp -d)"
c21_setup "$m1" $((MOCK_PORT_BASE + 940)) harness-3step '[{"id":"o1"}]'
touch "$m1/cr-state/paused"
c21_worker "$m1" $((MOCK_PORT_BASE + 940)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m1_claims="$(m3_tool_count "$m1" claim_render_order)"
m1_paused="$(grep -c '"tool": "set_computer_paused", "args": {"paused": true, "reason": "owner"}' "$m1/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$m1_claims" == "0" && "$m1_paused" == "1" && "$(m3_status "$m1" 'd["computer"]["paused"]')" == "True" && "$(m3_status "$m1" 'd["computer"]["pauseReason"]')" == "owner" ]]; then
  pass "paused: 0 claims, set_computer_paused(owner) once, status.json computer.paused=true"
else
  fail "paused" "claims=$m1_claims paused_calls=$m1_paused status=$(cat "$m1/cr-state/status.json" 2>/dev/null | head -c 300)"
fi
rm -rf "$m1"

echo "=== Case M3-01a-2: on battery → no claim (reason battery); allow-battery → claim ==="
m2="$(mktemp -d)"
c21_setup "$m2" $((MOCK_PORT_BASE + 941)) harness-3step '[]'
touch "$FAKE_PMSET_BATTERY"
c21_worker "$m2" $((MOCK_PORT_BASE + 941)) --once
m2_claims_a="$(m3_tool_count "$m2" claim_render_order)"
m2_batt="$(grep -c '"tool": "set_computer_paused", "args": {"paused": true, "reason": "battery"}' "$m2/mockstate/calls.jsonl" 2>/dev/null || true)"
touch "$m2/cr-state/allow-battery"
c21_worker "$m2" $((MOCK_PORT_BASE + 941)) --once
m2_claims_b="$(m3_tool_count "$m2" claim_render_order)"
rm -f "$FAKE_PMSET_BATTERY"
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
if [[ "$m2_claims_a" == "0" && "$m2_batt" == "1" && "$m2_claims_b" -ge 1 && -e "$m2/cr-state/allow-battery" ]]; then
  pass "battery: no claim + set_computer_paused(battery); allow-battery → claim ($m2_claims_b)"
else
  fail "battery" "claims_a=$m2_claims_a batt_calls=$m2_batt claims_b=$m2_claims_b; $(tail -3 "$m2/cr-state/cfw-render.log")"
fi
rm -rf "$m2"

echo "=== Case M3-01a-3: --loop run-now flag wakes the loop; lastCheckAt set ==="
m3="$(mktemp -d)"
c21_setup "$m3" $((MOCK_PORT_BASE + 942)) harness-3step '[]'
c21_worker "$m3" $((MOCK_PORT_BASE + 942)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=2 &
m3_w=$!
# wait for the first round (status.json appears), then ask for another now
for _ in $(seq 1 100); do [[ -f "$m3/cr-state/status.json" ]] && break; sleep 0.1; done
sleep 0.5
m3_before="$(m3_tool_count "$m3" claim_render_order)"
touch "$m3/cr-state/run-now"
m3_after="$m3_before"
for _ in $(seq 1 15); do m3_after="$(m3_tool_count "$m3" claim_render_order)"; [[ "$m3_after" -gt "$m3_before" ]] && break; sleep 0.1; done
m3_flag=0; [[ -e "$m3/cr-state/run-now" ]] && m3_flag=1
m3_last="$(m3_status "$m3" 'd["lastCheckAt"]')"
stop_test_tree "$m3_w" || { fail "loop cleanup" "could not stop owned tree"; exit 1; }
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
if [[ "$m3_after" -gt "$m3_before" && "$m3_flag" == "0" && -n "$m3_last" && "$m3_last" != "None" ]]; then
  pass "run-now: claims ${m3_before}→${m3_after} within 1.5s, flag consumed, lastCheckAt=$m3_last"
else
  fail "run-now" "before=$m3_before after=$m3_after flag=$m3_flag last='$m3_last'; $(tail -3 "$m3/cr-state/cfw-render.log")"
fi
rm -rf "$m3"

echo "=== Case M3-01a-4: capabilities.workerVersion rides on the claim; caffeinate wraps the order ==="
m4="$(mktemp -d)"
c21_setup "$m4" $((MOCK_PORT_BASE + 943)) harness-3step '[{"id":"o1"}]'
: > "$FAKE_CAFFEINATE_LOG"
c21_worker "$m4" $((MOCK_PORT_BASE + 943)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m4_ver="$(python3 -c '
import json,sys
for l in open(sys.argv[1]):
    d=json.loads(l)
    if d["tool"]=="claim_render_order": print(d["args"].get("capabilities",{}).get("workerVersion")); break' "$m4/mockstate/calls.jsonl" 2>/dev/null)"
if [[ "$m4_ver" == "1.1.0" && "$(m3_status "$m4" 'd["workerVersion"]')" == "1.1.0" ]]; then
  pass "version: claim capabilities.workerVersion=1.1.0, status.json version=1.1.0"
else
  fail "version" "workerVersion='$m4_ver' status=$(m3_status "$m4" 'd["workerVersion"]')"
fi
if grep -q -- '-i -w ' "$FAKE_CAFFEINATE_LOG"; then
  pass "sleep (D90): caffeinate -i -w <pid> started for the order"
else
  fail "caffeinate" "log: $(cat "$FAKE_CAFFEINATE_LOG")"
fi
# The fake caffeinate exits with its recorded worker; no host-wide cleanup.
rm -rf "$m4"

echo "=== Case M3-01a-5: updateRequired reply → no orders, status.json updateRequired + lastError ==="
m5="$(mktemp -d)"
c21_setup "$m5" $((MOCK_PORT_BASE + 944)) harness-3step '[{"id":"o1"}]' CFW_MOCK_UPDATE_REQUIRED=1
c21_worker "$m5" $((MOCK_PORT_BASE + 944)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m5_steps="$(m3_tool_count "$m5" report_render_step)"
if [[ "$m5_steps" == "0" && "$(m3_status "$m5" 'd["computer"]["updateRequired"]')" == "True" && "$(m3_status "$m5" 'd["lastError"]')" == "Update this computer" ]] && grep -q 'update required' "$m5/cr-state/cfw-render.log"; then
  pass "updateRequired: no orders started, status.json updateRequired=true lastError='Update this computer'"
else
  fail "updateRequired" "steps=$m5_steps status=$(head -c 400 "$m5/cr-state/status.json" 2>/dev/null); log: $(tail -4 "$m5/cr-state/cfw-render.log"); calls: $(cat "$m5/mockstate/calls.jsonl" | head -c 600)"
fi
rm -rf "$m5"

echo "=== Case M3-01a-6: older server without set_computer_paused → logged once, exit 0, no claims ==="
m6="$(mktemp -d)"
c21_setup "$m6" $((MOCK_PORT_BASE + 945)) harness-3step '[{"id":"o1"}]' CFW_MOCK_NO_M3_TOOLS=1
touch "$m6/cr-state/paused"
c21_worker "$m6" $((MOCK_PORT_BASE + 945)) --once; m6_rc=$?
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m6_lines="$(grep -c 'set_computer_paused' "$m6/cr-state/cfw-render.log" 2>/dev/null || true)"
if [[ "$m6_rc" == "0" && "$m6_lines" == "1" && "$(m3_tool_count "$m6" claim_render_order)" == "0" ]]; then
  pass "old server: set_computer_paused failure logged once, exit 0, 0 claims"
else
  fail "old server M3" "rc=$m6_rc lines=$m6_lines claims=$(m3_tool_count "$m6" claim_render_order); $(tail -3 "$m6/cr-state/cfw-render.log")"
fi
rm -rf "$m6"

# ---------------------------------------------------------------------------
# Handshake: a paused computer keeps checking in; `cfwReach` (ok |
# unreachable) comes only from real server calls and never touches lastError;
# plugging in, waking and the network coming back all claim promptly.
# ---------------------------------------------------------------------------
# A fake `date` whose +%s jumps by the seconds in $FAKE_DATE_OFFSET_FILE (as
# after the lid was shut). Named fake-date so PATH's date stays the real one.
cat > "$FAKE_BIN/fake-date" <<'EOF2'
#!/usr/bin/env bash
if [[ "${1:-}" == "+%s" ]]; then
  off="$(cat "${FAKE_DATE_OFFSET_FILE:-/nonexistent}" 2>/dev/null || echo 0)"
  [[ "$off" =~ ^[0-9]+$ ]] || off=0   # mid-write reads must yield a number
  now=$(( $(/bin/date +%s) + off ))
  echo "$now"
  # Optional barrier: the test can jump only after a loop sample was taken.
  [[ -z "${FAKE_DATE_TICK_FILE:-}" ]] || printf '%s\n' "$now" >> "$FAKE_DATE_TICK_FILE"
else
  exec /bin/date "$@"
fi
EOF2
chmod +x "$FAKE_BIN/fake-date"
# m3_until <tries> <sleep> <cmd...> — retry cmd until it succeeds; rc 1 when it never did.
m3_until() { local n="$1" s="$2" i; shift 2; for (( i = 0; i < n; i++ )); do "$@" && return 0; sleep "$s"; done; return 1; }
# m3_count <dir> <fixed string> — matching lines in calls.jsonl
m3_count() { grep -cF -- "$2" "$1/mockstate/calls.jsonl" 2>/dev/null || true; }
m3_count_ge() { (( $(m3_count "$1" "$2") >= $3 )); }
m3_log_count() { grep -cF -- "$2" "$1/cr-state/cfw-render.log" 2>/dev/null || true; }
m3_conn_is() { [[ "$(m3_status "$1" 'd.get("cfwReach")')" == "$2" ]]; }
m3_err_set() { local e; e="$(m3_status "$1" 'd.get("lastError")')"; [[ -n "$e" && "$e" != "None" ]]; }
# m3_stop_loop <worker pid> — stop the loop's whole tree and this case's mock
m3_stop_loop() {
  stop_test_tree "$1" || { fail "loop cleanup" "could not stop owned tree"; exit 1; }
  kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
}
M3_PING_BATTERY='"tool": "set_computer_paused", "args": {"paused": true, "reason": "battery"}'
M3_RESUME='"tool": "set_computer_paused", "args": {"paused": false}'
M3_CLAIM='"tool": "claim_render_order"'

echo "=== Case M3-01a-7: --loop on battery → a battery check-in every round, 0 claims; lastCheckAt advances; cfwReach ok ==="
p7="$(mktemp -d)"
c21_setup "$p7" $((MOCK_PORT_BASE + 946)) harness-3step '[]'
touch "$FAKE_PMSET_BATTERY"
c21_worker "$p7" $((MOCK_PORT_BASE + 946)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=0.3 &
p7_w=$!
m3_until 100 0.1 m3_count_ge "$p7" "$M3_PING_BATTERY" 1
m3_until 50 0.1 m3_conn_is "$p7" ok   # status.json lands after the call
p7_first="$(m3_status "$p7" 'd.get("lastCheckAt")')"
m3_until 100 0.1 m3_count_ge "$p7" "$M3_PING_BATTERY" 3
sleep 1.2   # lastCheckAt has one-second resolution
p7_last="$(m3_status "$p7" 'd.get("lastCheckAt")')"
p7_conn="$(m3_status "$p7" 'd.get("cfwReach")')"
m3_stop_loop "$p7_w"
rm -f "$FAKE_PMSET_BATTERY"
p7_pings="$(m3_count "$p7" "$M3_PING_BATTERY")"; p7_claims="$(m3_count "$p7" "$M3_CLAIM")"
if [[ "$p7_pings" -ge 3 && "$p7_claims" == "0" && -n "$p7_first" && "$p7_first" != "None" && "$p7_last" > "$p7_first" && "$p7_conn" == "ok" ]]; then
  pass "paused check-in: $p7_pings battery pings, 0 claims, lastCheckAt $p7_first → $p7_last, cfwReach ok"
else
  fail "paused check-in" "pings=$p7_pings claims=$p7_claims lastCheckAt '$p7_first' → '$p7_last' cfwReach=$p7_conn; $(tail -3 "$p7/cr-state/cfw-render.log")"
fi
rm -rf "$p7"

echo "=== Case M3-01a-8: paused, CFW unreachable → cfwReach unreachable (one log line); back → ok (one log line) ==="
p8="$(mktemp -d)"
c21_setup "$p8" $((MOCK_PORT_BASE + 947)) harness-3step '[]'
touch "$FAKE_PMSET_BATTERY"
c21_worker "$p8" $((MOCK_PORT_BASE + 947)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=0.3 &
p8_w=$!
m3_until 100 0.1 m3_conn_is "$p8" ok
touch "$p8/control/down"
m3_until 100 0.1 m3_conn_is "$p8" unreachable; p8_down_ok=$?
p8_since="$(m3_status "$p8" 'd.get("cfwReachSince")')"
# More failed check-ins must add no log line. Wait for an observable later
# round instead of a fixed sleep: lastCheckAt is stamped at the start of every
# round (one-second resolution) and a failed check-in spends >2 s in its
# retries, so the next status write after this one carries a later stamp.
p8_check0="$(m3_status "$p8" 'd.get("lastCheckAt")')"
m3_check_after() { local at; at="$(m3_status "$1" 'd.get("lastCheckAt")')"; [[ -n "$at" && "$at" > "$2" ]]; }
m3_until 100 0.1 m3_check_after "$p8" "$p8_check0"; p8_more_ok=$?
p8_still="$(m3_status "$p8" 'd.get("cfwReach")')"
rm -f "$p8/control/down"
p8_t0=$SECONDS
# Recovery bound: the round in flight may still spend its remaining soft-call
# retries (1 s apart) on 503s before the next round, 0.3 s later, reaches the
# server. 100 x 0.1 s is the same bound the outage detection above uses; the
# measured time is printed so a slow recovery stays visible.
m3_until 100 0.1 m3_conn_is "$p8" ok; p8_up_ok=$?
p8_secs=$(( SECONDS - p8_t0 ))
m3_stop_loop "$p8_w"
rm -f "$FAKE_PMSET_BATTERY"
p8_lost="$(m3_log_count "$p8" "connection: can't reach CFW")"
p8_back="$(m3_log_count "$p8" "connection: reached CFW again")"
if [[ "$p8_down_ok" == 0 && "$p8_more_ok" == 0 && "$p8_still" == unreachable && "$p8_up_ok" == 0 && -n "$p8_since" && "$p8_since" != "None" && "$p8_lost" == 1 && "$p8_back" == 1 ]]; then
  pass "paused offline: unreachable since $p8_since (1 line over repeated check-ins), ok again within ${p8_secs}s (1 line)"
else
  fail "paused offline" "down_ok=$p8_down_ok more_ok=$p8_more_ok still=$p8_still up_ok=$p8_up_ok since='$p8_since' lost_lines=$p8_lost back_lines=$p8_back; $(tail -4 "$p8/cr-state/cfw-render.log")"
fi
rm -rf "$p8"

# m3_keep_err <label> <dir> <port> <expected lastError glob> [mock env...] — run
# unpaused until lastError is set (no claim for an AI limit), then on battery,
# CFW down, CFW back: lastError reads the same at every checkpoint.
m3_keep_err() {
  local label="$1" dir="$2" port="$3" want="$4" w e0 e1 e2 e3 c1 c2 c3; shift 4
  c21_setup "$dir" "$port" harness-3step '[]' "$@"
  [[ -n "${M3_LIMITS_JSON:-}" ]] && printf '%s' "$M3_LIMITS_JSON" > "$dir/cr-state/engine-limits.json"
  c21_worker "$dir" "$port" --loop CFW_RENDER_CAPACITY_UNIT_SECS=0.3 &
  w=$!
  m3_until 100 0.1 m3_err_set "$dir"
  e0="$(m3_status "$dir" 'd.get("lastError")')"
  touch "$FAKE_PMSET_BATTERY"
  m3_until 100 0.1 m3_count_ge "$dir" "$M3_PING_BATTERY" 1
  m3_until 50 0.1 m3_conn_is "$dir" ok; c1="$(m3_status "$dir" 'd.get("cfwReach")')"
  e1="$(m3_status "$dir" 'd.get("lastError")')"
  touch "$dir/control/down"
  m3_until 100 0.1 m3_conn_is "$dir" unreachable; c2="$(m3_status "$dir" 'd.get("cfwReach")')"
  e2="$(m3_status "$dir" 'd.get("lastError")')"
  rm -f "$dir/control/down"
  m3_until 100 0.1 m3_conn_is "$dir" ok; c3="$(m3_status "$dir" 'd.get("cfwReach")')"
  e3="$(m3_status "$dir" 'd.get("lastError")')"
  m3_stop_loop "$w"
  rm -f "$FAKE_PMSET_BATTERY"
  # shellcheck disable=SC2053 # $want is a glob on purpose
  if [[ "$e0" == $want && "$e1" == "$e0" && "$e2" == "$e0" && "$e3" == "$e0" && "$c1/$c2/$c3" == "ok/unreachable/ok" ]]; then
    pass "$label: lastError '$e0' unchanged through battery, offline, online (cfwReach $c1/$c2/$c3)"
  else
    fail "$label" "lastError '$e0' / '$e1' / '$e2' / '$e3' (want $want) cfwReach $c1/$c2/$c3; $(tail -3 "$dir/cr-state/cfw-render.log")"
  fi
}
M3_HOUR="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

echo "=== Case M3-01a-9a: AI limit lastError survives the check-in's cfwReach flips ==="
p9a="$(mktemp -d)"
M3_LIMITS_JSON="{\"codex\":{\"until\":\"$M3_HOUR\"},\"claude-code\":{\"until\":\"$M3_HOUR\"}}" \
  m3_keep_err "AI limit" "$p9a" $((MOCK_PORT_BASE + 948)) 'AI limit reached; resumes *'
rm -rf "$p9a"

echo "=== Case M3-01a-9b: AI credit lastError survives the check-in's cfwReach flips ==="
p9b="$(mktemp -d)"
M3_LIMITS_JSON='{"codex":{"until":null,"reason":"credit"},"claude-code":{"until":null,"reason":"credit"}}' \
  m3_keep_err "AI credit" "$p9b" $((MOCK_PORT_BASE + 949)) 'AI credit ran out; add credit or pick another AI'
rm -rf "$p9b"

echo "=== Case M3-01a-9c: update-required lastError survives the check-in's cfwReach flips ==="
p9c="$(mktemp -d)"
M3_LIMITS_JSON="" m3_keep_err "update required" "$p9c" $((MOCK_PORT_BASE + 955)) 'Update this computer' CFW_MOCK_UPDATE_REQUIRED=1
rm -rf "$p9c"

echo "=== Case M3-01a-10: update required, claim fails then succeeds → cfwReach flips, lastError kept ==="
p10="$(mktemp -d)"
c21_setup "$p10" $((MOCK_PORT_BASE + 956)) harness-3step '[]' CFW_MOCK_UPDATE_REQUIRED=1
c21_worker "$p10" $((MOCK_PORT_BASE + 956)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=0.3 &
p10_w=$!
m3_until 100 0.1 m3_conn_is "$p10" ok
touch "$p10/control/down"
m3_until 200 0.1 m3_conn_is "$p10" unreachable; p10_c1="$(m3_status "$p10" 'd.get("cfwReach")')"
p10_e1="$(m3_status "$p10" 'd.get("lastError")')"
rm -f "$p10/control/down"
m3_until 200 0.1 m3_conn_is "$p10" ok; p10_c2="$(m3_status "$p10" 'd.get("cfwReach")')"
p10_e2="$(m3_status "$p10" 'd.get("lastError")')"
m3_stop_loop "$p10_w"
if [[ "$p10_c1/$p10_c2" == "unreachable/ok" && "$p10_e1" == "Update this computer" && "$p10_e2" == "Update this computer" ]]; then
  pass "claim path: cfwReach unreachable → ok, lastError 'Update this computer' both times"
else
  fail "claim path" "cfwReach $p10_c1/$p10_c2 lastError '$p10_e1' / '$p10_e2'; $(tail -4 "$p10/cr-state/cfw-render.log")"
fi
rm -rf "$p10"

echo "=== Case M3-01a-11: charger back in mid-loop → one {paused:false} and a claim within 1.5 s ==="
p11="$(mktemp -d)"
c21_setup "$p11" $((MOCK_PORT_BASE + 957)) harness-3step '[]'
touch "$FAKE_PMSET_BATTERY"
c21_worker "$p11" $((MOCK_PORT_BASE + 957)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=0.3 &
p11_w=$!
m3_until 100 0.1 m3_count_ge "$p11" "$M3_PING_BATTERY" 2
rm -f "$FAKE_PMSET_BATTERY"
m3_until 15 0.1 m3_count_ge "$p11" "$M3_CLAIM" 1; p11_ok=$?
p11_resume_at="$(m3_count "$p11" "$M3_RESUME")"
sleep 1   # more rounds: still exactly one resume
p11_resume="$(m3_count "$p11" "$M3_RESUME")"; p11_claims="$(m3_count "$p11" "$M3_CLAIM")"
m3_stop_loop "$p11_w"
if [[ "$p11_ok" == 0 && "$p11_resume_at" == 1 && "$p11_resume" == 1 && "$p11_claims" -ge 1 ]]; then
  pass "plugged in: {paused:false} once, $p11_claims claim(s), first within 1.5 s"
else
  fail "plugged in" "within=$p11_ok resume=$p11_resume_at/$p11_resume claims=$p11_claims; $(tail -3 "$p11/cr-state/cfw-render.log")"
fi
rm -rf "$p11"

echo "=== Case M3-01a-12: wake from sleep mid back-off → claim within 3 s, back-off reset ==="
p12="$(mktemp -d)"
c21_setup "$p12" $((MOCK_PORT_BASE + 958)) harness-3step '[]'
printf '0\n' > "$p12/date-offset.tmp" && mv "$p12/date-offset.tmp" "$p12/date-offset"
touch "$p12/control/down"
c21_worker "$p12" $((MOCK_PORT_BASE + 958)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=30 \
  CFW_RENDER_DATE_CMD="$FAKE_BIN/fake-date" FAKE_DATE_OFFSET_FILE="$p12/date-offset" &
p12_w=$!
m3_until 200 0.1 grep -qs 'retrying every 30s' "$p12/cr-state/cfw-render.log"; p12_backoff=$?
rm -f "$p12/control/down"
sleep 0.3
printf '3600\n' > "$p12/date-offset.tmp" && mv "$p12/date-offset.tmp" "$p12/date-offset"
m3_until 30 0.1 m3_count_ge "$p12" "$M3_CLAIM" 1; p12_ok=$?
p12_woke="$(m3_log_count "$p12" "woke from sleep")"; p12_reset="$(m3_log_count "$p12" "claim back-off: reset after sleep")"
m3_stop_loop "$p12_w"
if [[ "$p12_backoff" == 0 && "$p12_ok" == 0 && "$p12_woke" -ge 1 && "$p12_reset" -ge 1 ]]; then
  pass "wake: 'woke from sleep', back-off reset, claim within 3 s of the clock jump (not after the 30 s back-off)"
else
  fail "wake" "backoff_seen=$p12_backoff claimed=$p12_ok woke=$p12_woke reset=$p12_reset"
  # flake forensics: dump everything relevant while the dir still exists
  echo "--- p12 date-offset: $(cat "$p12/date-offset" 2>/dev/null); fake-date now: $(FAKE_DATE_OFFSET_FILE="$p12/date-offset" "$FAKE_BIN/fake-date" +%s 2>&1); real: $(/bin/date +%s)"
  echo "--- p12 control: $(ls "$p12/control" 2>/dev/null)"; echo "--- p12 status.json: $(cat "$p12/cr-state/status.json" 2>/dev/null)"
  echo "--- p12 worker log:"; tail -25 "$p12/cr-state/cfw-render.log" 2>/dev/null
  echo "--- p12 calls: $(cat "$p12/mockstate/calls.jsonl" 2>/dev/null)"
fi
rm -rf "$p12"

echo "=== Case M3-01a-12b: a 31 s clock jump exceeds a sub-two-second tick + wake gap ==="
# The old 15s real-time wait measured how quickly Python/MCP fixtures reached
# the cap, not the 31s wake boundary, and expired under parallel test load.
# Keep every scheduling assertion against the real production loop, with a
# deterministic clock. Cases 12 and 13 still exercise the real HTTP/loop path.
if short_tick_wake_case; then
  pass "wake: a 31 s jump exceeds tick 0.3 s + gap 30 s; back-off reset and a new claim"
else
  fail "short-tick wake" "real loop failed exact cap/tick/reset/claim assertions"
fi

echo "=== Case M3-01a-13: network back at the back-off cap → a claim within cap + one claim round ==="
p13="$(mktemp -d)"
c21_setup "$p13" $((MOCK_PORT_BASE + 959)) harness-3step '[]'
touch "$p13/control/down"
c21_worker "$p13" $((MOCK_PORT_BASE + 959)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=0.05 &
p13_w=$!
m3_until 120 0.5 grep -qs 'retrying every 0.5s' "$p13/cr-state/cfw-render.log"; p13_cap=$?
rm -f "$p13/control/down"
p13_t0=$SECONDS
# This mock returns a nonempty HTTP 503, so cr_mcp_call does not sleep/retry.
# Assert a successful claim AND its status within cap 0.5 s + 2 s slack.
m3_recovered() { m3_count_ge "$1" "$M3_CLAIM" 1 && m3_conn_is "$1" ok; }
m3_until 25 0.1 m3_recovered "$p13"; p13_ok=$?
p13_conn="$p13_ok"
p13_secs=$(( SECONDS - p13_t0 ))
m3_stop_loop "$p13_w"
if [[ "$p13_cap" == 0 && "$p13_ok" == 0 && "$p13_conn" == 0 ]]; then
  pass "at the cap: claim succeeded ${p13_secs}s after the network came back (bound 0.5 s + one round), cfwReach ok"
else
  fail "at the cap" "cap_seen=$p13_cap claimed=$p13_ok conn_ok=$p13_conn after ${p13_secs}s; $(tail -4 "$p13/cr-state/cfw-render.log")"
fi
rm -rf "$p13"
# ===========================================================================
# M3-07a — private toolchain: tools/current/bin PATH precedence + verify.sh
# ===========================================================================

echo "=== Case M3-07a-1: cr_resolve_worker_path prepends tools/current/bin when present ==="
m7_tmp="$(mktemp -d)"
mkdir -p "$m7_tmp/current/bin"
printf '#!/bin/sh\nexit 0\n' >"$m7_tmp/current/bin/ffmpeg"
chmod +x "$m7_tmp/current/bin/ffmpeg"
m7_out="$(
  export CFW_RENDER_TOOLS_DIR="$m7_tmp"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"
if [[ "$m7_out" == "$m7_tmp/current/bin:"* ]]; then
  pass "M3-07a-1: tools/current/bin is first on the worker PATH"
else
  fail "M3-07a-1" "expected prefix $m7_tmp/current/bin: in: $m7_out"
fi
rm -rf "$m7_tmp"

echo "=== Case M3-07a-2: absent tools dir leaves the worker PATH byte-identical ==="
m7_base="$(
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"
m7_none="$(
  export CFW_RENDER_TOOLS_DIR="/nonexistent/cfw-tools-$$"
  # shellcheck source=/dev/null
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_resolve_worker_path
)"
if [[ "$m7_base" == "$m7_none" && "$m7_none" != *"/nonexistent/"* ]]; then
  pass "M3-07a-2: no tools dir → PATH unchanged"
else
  fail "M3-07a-2" "base=$m7_base none=$m7_none"
fi

echo "=== Case M3-07a-3: make-sums.sh + verify.sh round-trip, then a flipped byte ==="
m7_b="$(mktemp -d)"
mkdir -p "$m7_b/bin"
printf 'hello\n' >"$m7_b/bin/a.txt"
printf 'world\n' >"$m7_b/notes.txt"
if "$REPO_DIR/toolchain/scripts/make-sums.sh" "$m7_b" >/dev/null \
   && [[ -s "$m7_b/SHA256SUMS" ]] \
   && "$REPO_DIR/toolchain/scripts/verify.sh" "$m7_b" >/dev/null; then
  pass "M3-07a-3: make-sums + verify → exit 0 on a clean dir"
else
  fail "M3-07a-3 clean" "verify did not pass on a freshly summed dir"
fi
printf 'hellp\n' >"$m7_b/bin/a.txt"
m7_v_out="$("$REPO_DIR/toolchain/scripts/verify.sh" "$m7_b" 2>&1)" && m7_v_rc=0 || m7_v_rc=$?
if [[ "$m7_v_rc" == "1" && "$m7_v_out" == *"bin/a.txt"* ]]; then
  pass "M3-07a-3: flipped byte → exit 1 naming bin/a.txt"
else
  fail "M3-07a-3 tamper" "rc=$m7_v_rc out=$m7_v_out"
fi
rm -rf "$m7_b"

echo "=== Case M3-07a-4: verify.sh Mach-O scan — system binary clean, Homebrew string flagged ==="
m7_m="$(mktemp -d)"
mkdir -p "$m7_m/bin"
cp /bin/ls "$m7_m/bin/ls"
if file -b "$m7_m/bin/ls" | grep -q 'Mach-O'; then
  "$REPO_DIR/toolchain/scripts/make-sums.sh" "$m7_m" >/dev/null
  m7_m_out="$("$REPO_DIR/toolchain/scripts/verify.sh" "$m7_m" 2>&1)" && m7_m_rc=0 || m7_m_rc=$?
  if [[ "$m7_m_rc" == "0" && "$m7_m_out" == *"1 Mach-O"* ]]; then
    pass "M3-07a-4: copy of /bin/ls → exit 0 (links /usr/lib only)"
  else
    fail "M3-07a-4 ls" "rc=$m7_m_rc out=$m7_m_out"
  fi
else
  pass "M3-07a-4: skipped (no Mach-O)"
fi
rm -rf "$m7_m"
m7_f="$(mktemp -d)"
mkdir -p "$m7_f/bin"
# Fake Mach-O: magic header (so `file` says Mach-O) + a Homebrew path string.
if file -b /bin/ls | grep -q 'Mach-O'; then
  head -c 4096 /bin/ls >"$m7_f/bin/fake"
else
  printf '\xcf\xfa\xed\xfe' >"$m7_f/bin/fake"
fi
printf '\n/opt/homebrew/lib/libfoo.dylib\n' >>"$m7_f/bin/fake"
"$REPO_DIR/toolchain/scripts/make-sums.sh" "$m7_f" >/dev/null
if file -b "$m7_f/bin/fake" | grep -q 'Mach-O'; then
  m7_f_out="$(CFW_VERIFY_FORCE_STRINGS=1 "$REPO_DIR/toolchain/scripts/verify.sh" "$m7_f" 2>&1)" && m7_f_rc=0 || m7_f_rc=$?
  if [[ "$m7_f_rc" == "1" && "$m7_f_out" == *"/opt/homebrew/lib/libfoo.dylib"* && "$m7_f_out" == *"strings"* ]]; then
    pass "M3-07a-4: strings fallback flags /opt/homebrew reference → exit 1"
  else
    fail "M3-07a-4 strings" "rc=$m7_f_rc out=$m7_f_out"
  fi
else
  pass "M3-07a-4: strings fallback skipped (file does not report Mach-O)"
fi
rm -rf "$m7_f"

# ===========================================================================
# [M3-01b] engines, usage limits, failover (contract §1/§3, D107/D109)
# ===========================================================================
m3b_fx="$REPO_DIR/test/fixtures/engine-limits"
m3b_detect() { CFW_RENDER_STATE_DIR="$1" bash -c 'cr_log(){ :; }; source "$1/bin/cfw-render-engine.sh"; cr_engine_limit_detect "$2" "$3" "$4"' _ "$REPO_DIR" "$2" "$3" "$4"; }
# m3b_started <dir> <orderId> — engines of step_started reports, in order
m3b_started() { python3 -c '
import json, sys
print(" ".join("%s:%s" % (d.get("stepId"), d.get("engine")) for d in (json.loads(l) for l in open(sys.argv[1]) if l.strip()) if d["event"] == "step_started" and d["orderId"] == sys.argv[2]))' "$1/control/reports.ndjson" "$2" 2>/dev/null; }
m3b_calls_of() { python3 -c '
import json, sys
print("\n".join(json.dumps(json.loads(l)["args"]) for l in open(sys.argv[1]) if json.loads(l)["tool"] == sys.argv[2]))' "$1/mockstate/calls.jsonl" "$2" 2>/dev/null; }

echo "=== Case M3-01b-1: cr_engine_limit_detect on vendor fixtures ==="
mb1="$(mktemp -d)"
mb1_a="$(m3b_detect "$mb1" codex "$m3b_fx/codex-limit.txt" 1)" && mb1_a_rc=0 || mb1_a_rc=$?
mb1_b="$(m3b_detect "$mb1" claude-code "$m3b_fx/claude-limit.txt" 0)" && mb1_b_rc=0 || mb1_b_rc=$?
mb1_c="$(m3b_detect "$mb1" codex "$m3b_fx/codex-ok.txt" 1)" && mb1_c_rc=0 || mb1_c_rc=$?
if [[ "$mb1_a_rc" == "0" && "$mb1_a" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:40:00Z$ && "$mb1_b_rc" == "0" && "$mb1_b" =~ ^[0-9]{4}- && "$mb1_c_rc" == "1" && -z "$mb1_c" ]]; then
  pass "limit detect: codex-limit → $mb1_a; claude-limit → $mb1_b; codex-ok → rc 1"
else
  fail "limit detect" "codex rc=$mb1_a_rc out=$mb1_a; claude rc=$mb1_b_rc out=$mb1_b; ok rc=$mb1_c_rc out=$mb1_c"
fi
rm -rf "$mb1"

echo "=== Case M3-01b-2: codex hits its limit on step a → step reruns on claude-code, attempt completes ==="
mb2="$(mktemp -d)"
c21_setup "$mb2" $((MOCK_PORT_BASE + 950)) harness-3step '[{"id":"o1"}]'
c21_worker "$mb2" $((MOCK_PORT_BASE + 950)) --once FAKE_ENGINE_LIMIT_ENGINE=codex FAKE_ENGINE_LIMIT_STEP=a
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mb2_started="$(m3b_started "$mb2" o1)"
mb2_ev="$(c21_events_for "$mb2/control/reports.ndjson" o1)"
mb2_lim="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("codex" if "codex" in d else "no")' "$mb2/cr-state/engine-limits.json" 2>/dev/null)"
if [[ "$mb2_started" == "a:codex a:claude-code c:claude-code" && "$mb2_ev" == *"step_completed:a"* && "$mb2_ev" == *"attempt_completed:-"* && "$mb2_lim" == "codex" ]]; then
  pass "failover: step_started a:codex → a:claude-code, completed; engine-limits.json has codex"
else
  fail "failover" "started='$mb2_started' events='$mb2_ev' limits=$mb2_lim; $(tail -5 "$mb2/cr-state/cfw-render.log" 2>/dev/null)"
fi
rm -rf "$mb2"

echo "=== Case M3-01b-3: every engine limited → attempt_released(engine_limit), set_computer_limit(until); next pass claims nothing ==="
mb3="$(mktemp -d)"
c21_setup "$mb3" $((MOCK_PORT_BASE + 951)) harness-3step '[{"id":"o1"}]'
c21_worker "$mb3" $((MOCK_PORT_BASE + 951)) --once FAKE_ENGINE_LIMIT_ENGINE=all FAKE_ENGINE_LIMIT_STEP=a
mb3_ev="$(c21_events_for "$mb3/control/reports.ndjson" o1)"
mb3_rel="$(grep -c '"event": "attempt_released"' "$mb3/control/reports.ndjson" 2>/dev/null || true)"
mb3_reason="$(python3 -c '
import json,sys
print(" ".join(d.get("reason") or "-" for d in (json.loads(l) for l in open(sys.argv[1]) if l.strip()) if d["event"]=="attempt_released"))' "$mb3/control/reports.ndjson" 2>/dev/null)"
mb3_lim="$(m3b_calls_of "$mb3" set_computer_limit)"
mb3_failed="$(grep -c '"event": "attempt_failed"' "$mb3/control/reports.ndjson" 2>/dev/null || true)"
mb3_claims_a="$(m3_tool_count "$mb3" claim_render_order)"
c21_worker "$mb3" $((MOCK_PORT_BASE + 951)) --once FAKE_ENGINE_LIMIT_ENGINE=all FAKE_ENGINE_LIMIT_STEP=a
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mb3_claims_b="$(m3_tool_count "$mb3" claim_render_order)"
mb3_status="$(m3_status "$mb3" '" ".join(e["limit"] for e in d["engines"] if e["signedIn"])')"
mb3_err="$(m3_status "$mb3" 'd["lastError"]')"
if [[ "$mb3_rel" == "1" && "$mb3_reason" == "engine_limit" && "$(wc -l <<< "$mb3_lim" | tr -d ' ')" == "1" && "$mb3_lim" == *'"until": "20'* && "$mb3_failed" == "0" && "$mb3_claims_b" == "$mb3_claims_a" && "$mb3_status" == "limited limited" && "$mb3_err" == "AI limit reached; resumes "* ]]; then
  pass "both limited: attempt_released(engine_limit) once, set_computer_limit once with until, no attempt_failed; 2nd pass 0 claims, status engines=limited limited"
else
  fail "both limited" "released=$mb3_rel reason=$mb3_reason limit_calls='$mb3_lim' failed=$mb3_failed claims=$mb3_claims_a/$mb3_claims_b status='$mb3_status' err='$mb3_err' ev='$mb3_ev'"
fi
rm -rf "$mb3"

echo "=== Case M3-01b-4: engines.json order → capabilities.engine and engines[0] are claude-code ==="
mb4="$(mktemp -d)"
c21_setup "$mb4" $((MOCK_PORT_BASE + 952)) harness-3step '[]'
printf '{"order":["claude-code","codex"]}' > "$mb4/cr-state/engines.json"
c21_worker "$mb4" $((MOCK_PORT_BASE + 952)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mb4_caps="$(python3 -c '
import json,sys
for l in open(sys.argv[1]):
    d=json.loads(l)
    if d["tool"]=="claim_render_order":
        c=d["args"]["capabilities"]; print(c["engine"], c["engines"][0]["name"], c["engines"][1]["name"]); break' "$mb4/mockstate/calls.jsonl" 2>/dev/null)"
if [[ "$mb4_caps" == "claude-code claude-code codex" ]]; then
  pass "engine order: capabilities.engine=claude-code, engines=[claude-code, codex]"
else
  fail "engine order" "caps='$mb4_caps'"
fi
rm -rf "$mb4"

echo "=== Case M3-01b-5: expired codex limit → claim with codex, entry cleared, set_computer_limit(until=null) ==="
mb5="$(mktemp -d)"
c21_setup "$mb5" $((MOCK_PORT_BASE + 953)) harness-3step '[{"id":"o1"}]'
python3 -c '
import json,sys,datetime
t=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"codex":{"until":t}}, open(sys.argv[1],"w"))' "$mb5/cr-state/engine-limits.json"
c21_worker "$mb5" $((MOCK_PORT_BASE + 953)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mb5_engine="$(python3 -c '
import json,sys
for l in open(sys.argv[1]):
    d=json.loads(l)
    if d["tool"]=="claim_render_order": print(d["args"]["capabilities"]["engine"]); break' "$mb5/mockstate/calls.jsonl" 2>/dev/null)"
mb5_file="$(python3 -c 'import json,sys; print("codex" if "codex" in json.load(open(sys.argv[1])) else "clear")' "$mb5/cr-state/engine-limits.json" 2>/dev/null)"
mb5_ev="$(c21_events_for "$mb5/control/reports.ndjson" o1)"
mb5_null="$(m3b_calls_of "$mb5" set_computer_limit | grep -c '"until": null' || true)"
if [[ "$mb5_engine" == "codex" && "$mb5_file" == "clear" && "$mb5_ev" == *"attempt_completed:-"* && "$mb5_null" -ge 1 ]]; then
  pass "expired limit: claimed with codex, engine-limits.json cleared, set_computer_limit(until=null), attempt completed"
else
  fail "expired limit" "engine=$mb5_engine file=$mb5_file ev='$mb5_ev' limit_calls='$(m3b_calls_of "$mb5" set_computer_limit)'"
fi
rm -rf "$mb5"

echo "=== Case M3-01b-6: status.json now shows the running step, empty afterwards ==="
mb6="$(mktemp -d)"
c21_setup "$mb6" $((MOCK_PORT_BASE + 954)) harness-3step '[{"id":"o1"}]'
c21_worker "$mb6" $((MOCK_PORT_BASE + 954)) --loop CFW_RENDER_CAPACITY_UNIT_SECS=1 FAKE_ENGINE_SLEEP=3 &
mb6_w=$!
mb6_req=""
for _ in $(seq 1 120); do mb6_req="$(m3_status "$mb6" '" ".join("%s/%s/%s" % (r["step"], r["steps"], r["stepLabel"]) for r in d["now"])')"; [[ -n "$mb6_req" ]] && break; sleep 0.1; done
mb6_after="x"
for _ in $(seq 1 200); do mb6_after="$(m3_status "$mb6" 'len(d["now"])')"; [[ "$mb6_after" == "0" ]] && grep -q '"event": "attempt_completed"' "$mb6/control/reports.ndjson" 2>/dev/null && break; sleep 0.1; done
stop_test_tree "$mb6_w" || { fail "loop cleanup" "could not stop owned tree"; exit 1; }
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mb6_want="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); s=[x for x in m["steps"] if x.get("runsOn","computer")=="computer"]; print("1/%d/%s" % (len(s), s[0].get("label")))' "$REPO_DIR/test/fixtures/manifests/harness-3step/manifest.json")"
if [[ "$mb6_req" == "$mb6_want"* && "$mb6_after" == "0" && "$(m3_status "$mb6" 'd["activeEngine"]')" == "codex" ]]; then
  pass "status now: '$mb6_req' while running, empty after; activeEngine=codex"
else
  fail "status now" "during='$mb6_req' after=$mb6_after status=$(head -c 400 "$mb6/cr-state/status.json" 2>/dev/null)"
fi
rm -rf "$mb6"
echo "=== Case M3-07b-1: release.sh dry run writes toolchain-manifest.json with matching sha256 + versioned urls ==="
m7b_d="$(mktemp -d)"
m7b_ver="$(python3 -c 'import json;print(json.load(open("'"$REPO_DIR"'/toolchain/manifest.json"))["version"])')"
printf 'fake-arm\n' >"$m7b_d/cfw-toolchain-$m7b_ver-arm64.tar.zst"
printf 'fake-x86 longer\n' >"$m7b_d/cfw-toolchain-$m7b_ver-x86_64.tar.zst"
m7b_out="$(CFW_RELEASE_DRY_RUN=1 "$REPO_DIR/toolchain/scripts/release.sh" "$m7b_d" 2>&1)" && m7b_rc=0 || m7b_rc=$?
m7b_want_a="$(shasum -a 256 "$m7b_d/cfw-toolchain-$m7b_ver-arm64.tar.zst" | awk '{print $1}')"
m7b_want_x="$(shasum -a 256 "$m7b_d/cfw-toolchain-$m7b_ver-x86_64.tar.zst" | awk '{print $1}')"
m7b_chk="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); a=d["archives"]
ok = a["arm64"]["sha256"]==sys.argv[2] and a["x86_64"]["sha256"]==sys.argv[3] \
  and ("/toolchain/%s/" % d["version"]) in a["arm64"]["url"] and ("/toolchain/%s/" % d["version"]) in a["x86_64"]["url"] \
  and a["x86_64"]["sizeBytes"]==16 and d.get("publishedAt") and d.get("minAppVersion")
print("ok" if ok else "bad")' "$m7b_d/toolchain-manifest.json" "$m7b_want_a" "$m7b_want_x" 2>&1)"
if [[ "$m7b_rc" == "0" && "$m7b_chk" == "ok" && "$m7b_out" == *"DRY: aws s3 cp"*"toolchain/manifest.json"* ]]; then
  pass "M3-07b-1: release.sh dry run → manifest sha256/url/size correct, aws commands printed"
else
  fail "M3-07b-1" "rc=$m7b_rc chk=$m7b_chk out=$m7b_out"
fi
rm -rf "$m7b_d"

echo "=== Case M3-07b-2: build.sh refuses TODO-* sha256 pins unless CFW_TOOLCHAIN_ALLOW_UNPINNED=1 ==="
m7b_t="$(mktemp -d)"
cat >"$m7b_t/manifest.json" <<'JSON'
{"version":"0.0.0-test","minAppVersion":"1.0.0","tools":[
 {"name":"node","version":"1","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},
 {"name":"zzz-unpinned-tool","version":"1","sha256":"TODO-fill-from-first-build"}]}
JSON
m7b_out="$(
  unset CFW_TOOLCHAIN_ALLOW_UNPINNED
  CFW_TOOLCHAIN_MANIFEST="$m7b_t/manifest.json" "$REPO_DIR/toolchain/scripts/build.sh" arm64 "$m7b_t/dist" 2>&1
)" && m7b_rc=0 || m7b_rc=$?
if [[ "$m7b_rc" != "0" && "$m7b_out" == *"unpinned"* && "$m7b_out" == *"zzz-unpinned-tool"* && "$m7b_out" != *"fetch:"* ]]; then
  pass "M3-07b-2: unpinned tool → exit $m7b_rc, message names zzz-unpinned-tool, nothing fetched"
else
  fail "M3-07b-2" "rc=$m7b_rc out=$m7b_out"
fi
rm -rf "$m7b_t"

echo "=== Case M3-07b-3: manifest.json parses; tc_arch_triple maps arm64/x86_64 ==="
m7b_tr="$(
  # shellcheck source=/dev/null
  source "$REPO_DIR/toolchain/scripts/lib.sh"
  printf '%s %s' "$(tc_arch_triple arm64)" "$(tc_arch_triple x86_64)"
)"
if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$REPO_DIR/toolchain/manifest.json" \
   && [[ "$m7b_tr" == "aarch64-apple-darwin x86_64-apple-darwin" ]]; then
  pass "M3-07b-3: manifest valid JSON; triples = $m7b_tr"
else
  fail "M3-07b-3" "triples=$m7b_tr"
fi

echo "=== Case M3-01c-1: status.json has exactly the contract keys; engines labelled; activeEngine null for none ==="
mc1="$(mktemp -d)"
c21_setup "$mc1" $((MOCK_PORT_BASE + 960)) harness-3step '[]'
c21_worker "$mc1" $((MOCK_PORT_BASE + 960)) --once CFW_RENDER_ENGINE=none CFW_RENDER_COMPUTER_NAME="Test Mac"
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mc1_keys="$(m3_status "$mc1" '",".join(sorted(d))')"
mc1_want="$(python3 -c 'print(",".join(sorted("schema workerVersion engines activeEngine computer brands now next recent lastCheckAt lastError cfwReach cfwReachSince connection".split())))')"
mc1_eng="$(m3_status "$mc1" 'all("label" in e and e["auth"] == "signin" for e in d["engines"])')"
mc1_rest="$(m3_status "$mc1" '(d["schema"], d["activeEngine"], d["computer"]["name"], d["next"])')"
if [[ "$mc1_keys" == "$mc1_want" && "$mc1_eng" == "True" && "$mc1_rest" == "(1, None, 'Test Mac', [])" ]]; then
  pass "status contract: keys exact, schema 1, engines labelled, activeEngine null"
else
  fail "status contract" "keys=$mc1_keys eng=$mc1_eng rest=$mc1_rest"
fi
rm -rf "$mc1"

echo "=== Case M3-01c-2: claim reply computerBrands → status brands ==="
mc2="$(mktemp -d)"
c21_setup "$mc2" $((MOCK_PORT_BASE + 961)) harness-3step '[]' 'CFW_MOCK_COMPUTER_BRANDS=[{"id":"b1","name":"Brand A"}]'
c21_worker "$mc2" $((MOCK_PORT_BASE + 961)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mc2_b="$(m3_status "$mc2" 'd["brands"] == [{"id": "b1", "name": "Brand A", "serving": True, "slug": None}]')"
if [[ "$mc2_b" == "True" ]]; then
  pass "status brands from computerBrands"
else
  fail "status brands" "status=$(head -c 400 "$mc2/cr-state/status.json" 2>/dev/null)"
fi
rm -rf "$mc2"

echo "=== Case M3-01c-3: a completed order lands in status recent ==="
mc3="$(mktemp -d)"
c21_setup "$mc3" $((MOCK_PORT_BASE + 962)) harness-3step '[{"id":"o1"}]' 'CFW_MOCK_ORDER_EXTRA={"shortCode":"R-TEST","brandName":"Brand A"}'
c21_worker "$mc3" $((MOCK_PORT_BASE + 962)) --once
c21_worker "$mc3" $((MOCK_PORT_BASE + 962)) --once
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mc3_r="$(m3_status "$mc3" 'sorted(d["recent"][0]) == ["attemptId","brand","brandSlug","directorLog","finishedAt","kind","orderId","reason","recipe","result","shortCode","startedAt"] and (d["recent"][0]["shortCode"], d["recent"][0]["brand"], d["recent"][0]["result"]) == ("R-TEST","Brand A","done") and d["recent"][0]["finishedAt"].endswith("Z") and d["recent"][0]["orderId"] == "o1" and d["recent"][0]["attemptId"] == "att_1" and d["recent"][0]["brandSlug"] == "test-brand" and d["recent"][0]["recipe"] == "harness-3step" and d["recent"][0]["startedAt"].endswith("Z") and d["recent"][0]["directorLog"] is None and d["recent"][0]["reason"] is None')"
if [[ "$mc3_r" == "True" ]]; then
  pass "status recent: R-TEST / Brand A / done"
else
  fail "status recent" "status=$(head -c 600 "$mc3/cr-state/status.json" 2>/dev/null) ndjson=$(cat "$mc3/cr-state/recent.ndjson" 2>/dev/null)"
fi
rm -rf "$mc3"

st_py() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$CASE_STATE/status.json" "$1" 2>/dev/null; }
echo "=== Case M3-01c-6: Up next comes from CFW's list_render_queue; an older server shows nothing stale ==="
CFW_MOCK_QUEUE='[{"id":"q1","shortCode":"R-Q1","brandName":"Brand B","brandSlug":"brand-b","kind":"image","recipe":"p-gfx-image","status":"needs_input","needs":"Waiting for your input","createdAt":"2026-10-13T00:00:00Z","urgent":false}]' \
  run_case "queue" "happy" "echo []" true
q="$(st_py 'd["next"]')"
if [[ "$q" == "[{'orderId': 'q1', 'shortCode': 'R-Q1', 'brand': 'Brand B', 'brandSlug': 'brand-b', 'kind': 'image', 'recipe': 'p-gfx-image', 'status': 'needs_input', 'needs': 'Waiting for your input', 'createdAt': '2026-10-13T00:00:00Z'}]" ]]; then
  pass "status next: the waiting list across brands, with needs-you rows"
else
  fail "status next" "$q calls=$(grep list_render_queue "$CASE_MOCKSTATE/calls.jsonl" | head -2)"
fi
run_case "queue-old-server" "happy" "echo []" true
if [[ "$(st_py 'd["next"]')" == "[]" && ! -e "$CASE_STATE/next.json" ]]; then
  pass "status next: a server without list_render_queue → empty, no stale file"
else
  fail "status next old server" "$(st_py 'd["next"]')"
fi

echo "=== Case M3-01c-4: status.json never holds the worker key or the word token ==="
mc4="$(mktemp -d)"
# A well-formed key (the worker refuses any other shape) with a random tail,
# built at runtime so this file holds nothing key-like.
mc4_key="cfw_render_m3probe$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
c21_setup "$mc4" $((MOCK_PORT_BASE + 963)) harness-3step '[{"id":"o1"}]'
c21_worker "$mc4" $((MOCK_PORT_BASE + 963)) --once CFW_RENDER_WORKER_KEY="$mc4_key"
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
mc4_claims="$(grep -c '"tool": "claim_render_order"' "$mc4/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$mc4_claims" -ge 1 && -f "$mc4/cr-state/status.json" ]] && ! grep -q "$mc4_key" "$mc4/cr-state/status.json" && ! grep -qi 'token' "$mc4/cr-state/status.json"; then
  pass "status.json holds no key or token (worker ran: $mc4_claims claim(s))"
else
  fail "status secrets" "claims=$mc4_claims status=$(head -c 400 "$mc4/cr-state/status.json" 2>/dev/null)"
fi
rm -rf "$mc4"

# ── M3-04a: install.sh --from-app (app-driven, no prompts, JSON steps) ──
m4_browser_cache="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/Library/Caches/ms-playwright}"
# m4_setup <dir> <port> [mock KEY=VALUE...] — temp HOME + mock server.
m4_setup() {
  local dir="$1" port="$2"; shift 2
  mkdir -p "$dir/home" "$dir/prefix" "$dir/mockstate"
  echo '[]' > "$dir/queue.json"
  m4_pid="$(
    for kv in "$@"; do export "${kv?}"; done
    start_mock "$dir/queue.json" "$dir/mockstate" "$port"
  )"
}
# m4_run <dir> <port> <stdin-file> [KEY=VALUE...] — sets m4_rc.
m4_run() {
  local dir="$1" port="$2" in="$3"; shift 3
  (
    export HOME="$dir/home"
    export PATH="$REPO_DIR/bin:$FAKE_BIN:$PATH"
    export PLAYWRIGHT_BROWSERS_PATH="$m4_browser_cache"
    export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
    export CFW_RENDER_API_BASE="http://127.0.0.1:$port"
    export CFW_RENDER_SKIP_LAUNCHCTL=1 CFW_RENDER_PROBE_POLL_SEC=0.1
    for kv in "$@"; do export "${kv?}"; done
    "$REPO_DIR/install/install.sh" --mode byoa --non-interactive --from-app --prefix "$dir/prefix" \
      < "$in" > "$dir/out.jsonl" 2> "$dir/err.log"
  )
  m4_rc=$?
}
m4_steps() { python3 -c '
import json, sys
print(" ".join(f"{(o:=json.loads(l))["step"]}:{o["state"]}" for l in open(sys.argv[1]) if l.strip()))' "$1/out.jsonl" 2>/dev/null || echo "NONJSON"; }

echo "=== Case M3-04a-1/2: --from-app happy path; brand key never leaks ==="
m4a="$(mktemp -d)"
# Real CFW keys are base64url (~40% contain '-'): always include one here.
m4a_key="cfw_m4-brand$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
printf '%s\n' "$m4a_key" > "$m4a/stdin"
m4_setup "$m4a" $((MOCK_PORT_BASE + 970))
# Inspect only this test runner's descendants, never unrelated host argv.
( for _ in $(seq 1 600); do python3 "$TEST_DIR/stop-owned-tree.py" --arguments "$$"; sleep 0.05; done ) > "$m4a/ps.log" 2>/dev/null &
m4a_ps=$!
m4_run "$m4a" $((MOCK_PORT_BASE + 970)) "$m4a/stdin"
stop_test_tree "$m4a_ps" || { fail "argv watcher cleanup" "could not stop owned tree"; exit 1; }
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
rm -f "$m4a/stdin"
m4a_steps="$(m4_steps "$m4a")"
m4a_want="checking:started checking:done installing:started installing:done connecting:started connecting:done test_render:started test_render:done ready:done"
m4a_envf="$m4a/home/.cfw-render/cfw-render.env"
m4a_mode="$(stat -f '%Lp' "$m4a_envf" 2>/dev/null || stat -c '%a' "$m4a_envf" 2>/dev/null)"
m4a_origin="$(python3 -c '
import json, sys
c = [json.loads(l) for l in open(sys.argv[1])]
r = [x for x in c if x["tool"] == "report_byoa_setup_step"]
steps = [x["args"]["step"] for x in r]
print(all(x["args"].get("origin") == "app" for x in r), steps[:3], steps.count("probe_render"),
      sum(1 for x in c if x["tool"] == "create_probe_render_order"))' "$m4a/mockstate/calls.jsonl" 2>/dev/null)"
if [[ "$m4_rc" == "0" && "$m4a_steps" == "$m4a_want" ]]; then
  pass "from-app: exit 0, stdout only JSON, steps in order with started+done"
else
  fail "from-app happy path" "rc=$m4_rc steps=$m4a_steps err=$(tail -15 "$m4a/err.log")"
fi
if grep -q '^CFW_RENDER_WORKER_KEY=cfw_render_mock-brand_xchg-0Ab9_Zq1$' "$m4a_envf" 2>/dev/null && [[ "$m4a_mode" == "600" ]]; then
  pass "from-app: env file holds the exchanged render key, mode 600"
else
  fail "from-app env file" "mode=$m4a_mode"
fi
if [[ "$m4a_origin" == "True ['deps', 'credential', 'recipe_fetch'] 3 1" ]]; then
  pass "from-app: setup reports carry origin app; probe polled until ready"
else
  fail "from-app reports" "$m4a_origin"
fi
m4a_ps_lines="$(wc -l < "$m4a/ps.log" | tr -d ' ')"
if ! grep -rqF "$m4a_key" "$m4a/out.jsonl" "$m4a/err.log" "$m4a/home" "$m4a/prefix" "$m4a/mockstate" "$m4a/mock-server.log" "$m4a/ps.log" 2>/dev/null \
   && [[ "$m4a_ps_lines" -gt 0 ]]; then
  pass "from-app: brand key nowhere (stdout, stderr, HOME, mock log, argv over $m4a_ps_lines ps lines)"
else
  fail "from-app brand key leak" "$(grep -rlF "$m4a_key" "$m4a" 2>/dev/null)"
fi
if cmp -s "$REPO_DIR/VERSION" "$m4a/prefix/VERSION" \
   && cmp -s "$REPO_DIR/lib/render-debug.py" "$m4a/prefix/lib/render-debug.py" \
   && cmp -s "$REPO_DIR/bin/cfw-render-stage.py" "$m4a/prefix/bin/cfw-render-stage.py"; then
  pass "fresh app install preserves version, debug and bounded-stage helpers"
else
  fail "fresh app install bundle" "missing or stale VERSION/debug/stage helper"
fi
if python3 - "$m4a/home/.cfw-render/connection.json" <<'PY_CONNECTION'
import json, sys
c = json.load(open(sys.argv[1]))
assert set(c) == {"scope", "keyName", "keyHint", "connectedAt"}
assert c["scope"] == "brand" and c["connectedAt"].endswith("Z")
assert c["keyHint"].startswith("cfw_render_") and len(c["keyHint"]) <= 18
assert "xchg-0Ab9" not in json.dumps(c)
PY_CONNECTION
then
  pass "connection metadata contains reach and short hint, not exchanged secret"
else
  fail "connection metadata" "wrong shape, reach or key hint"
fi
rm -rf "$m4a"

echo "=== Case M3-04a-2c: a fresh computer opens its setup session first; the probe report names the tested brand ==="
m4f="$(mktemp -d)"
printf '%s\n' "cfw_m4-fresh$(python3 -c 'import secrets;print(secrets.token_hex(8))')" > "$m4f/stdin"
m4_setup "$m4f" $((MOCK_PORT_BASE + 976)) CFW_MOCK_REQUIRE_SETUP_SESSION=1 CFW_MOCK_PROBE_BRAND=brand_tested_1 CFW_MOCK_EXCHANGE_SCOPE=user
m4_run "$m4f" $((MOCK_PORT_BASE + 976)) "$m4f/stdin"
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
m4f_seq="$(python3 -c '
import json, sys
c = [json.loads(l) for l in open(sys.argv[1])]
setup = [x for x in c if x["tool"] in ("get_byoa_setup_instructions", "report_byoa_setup_step")]
first = setup[0]["tool"] if setup else None
probe = [x["args"].get("brandId") for x in c if x["tool"] == "report_byoa_setup_step" and x["args"].get("step") == "probe_render"]
# probe_render polls answer "not done" until the probe finishes; every other setup call must succeed.
print(first, all(x["ok"] for x in setup if x["args"].get("step") != "probe_render"), sorted(set(probe)))' "$m4f/mockstate/calls.jsonl" 2>/dev/null)"
if [[ "$m4_rc" == "0" && "$m4f_seq" == "get_byoa_setup_instructions True ['brand_tested_1']" ]]; then
  pass "from-app: setup session opened before any report; probe_render reports carry the tested brandId"
else
  fail "from-app setup session" "rc=$m4_rc seq=$m4f_seq err=$(tail -5 "$m4f/err.log")"
fi
rm -rf "$m4f"

echo "=== Case M3-04a-2b: switching keys (all brands) turns off this Mac's old key after the test render ==="
m4s="$(mktemp -d)"
m4s_old="cfw_render_oldkey_$(python3 -c 'import secrets;print(secrets.token_hex(4))')"
m4s_key="cfw_m4-acct$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
printf '%s\n' "$m4s_key" > "$m4s/stdin"
m4_setup "$m4s" $((MOCK_PORT_BASE + 975)) CFW_MOCK_EXCHANGE_SCOPE=user
mkdir -p "$m4s/home/.cfw-render"
( umask 077; printf 'CFW_API_BASE=http://127.0.0.1:%s\nCFW_RENDER_WORKER_KEY=%s\n' $((MOCK_PORT_BASE + 975)) "$m4s_old" > "$m4s/home/.cfw-render/cfw-render.env" )
m4_run "$m4s" $((MOCK_PORT_BASE + 975)) "$m4s/stdin"
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
m4s_revoked="$(python3 -c '
import json, sys
print([json.loads(l)["args"]["keyTail"] for l in open(sys.argv[1]) if "revoke_key_used" in l])' "$m4s/mockstate/calls.jsonl" 2>/dev/null)"
m4s_scope="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["scope"])' "$m4s/home/.cfw-render/connection.json" 2>/dev/null)"
if [[ "$m4_rc" == "0" && "$m4s_revoked" == "['${m4s_old: -6}']" && "$m4s_scope" == "user" ]] \
   && grep -q '^CFW_RENDER_WORKER_KEY=cfw_render_mock-brand_xchg' "$m4s/home/.cfw-render/cfw-render.env" \
   && ! grep -qF "$m4s_old" "$m4s/home/.cfw-render/cfw-render.env" "$m4s/out.jsonl" "$m4s/err.log"; then
  pass "from-app re-setup: new key saved, old key revoked with itself (once), connection says all brands"
else
  fail "from-app re-setup" "rc=$m4_rc revoked=$m4s_revoked scope=$m4s_scope err=$(tail -5 "$m4s/err.log")"
fi
rm -rf "$m4s"

echo "=== Case M3-04a-3: bad key → connecting failed, exit 5, no key written ==="
m4b="$(mktemp -d)"
printf 'cfw_bad\n' > "$m4b/stdin"
m4_setup "$m4b" $((MOCK_PORT_BASE + 971))
m4_run "$m4b" $((MOCK_PORT_BASE + 971)) "$m4b/stdin"
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
m4b_steps="$(m4_steps "$m4b")"
if [[ "$m4_rc" == "5" && "$m4b_steps" == *"connecting:failed" ]] && ! grep -q 'CFW_RENDER_WORKER_KEY=' "$m4b/home/.cfw-render/cfw-render.env" 2>/dev/null; then
  pass "from-app: bad key → connecting failed, exit 5, no key written"
else
  fail "from-app bad key" "rc=$m4_rc steps=$m4b_steps"
fi
rm -rf "$m4b"

echo "=== Case M3-04a-4: no engine → checking failed, exit 3, AI Providers action ==="
m4c="$(mktemp -d)"
printf 'cfw_goodkey\n' > "$m4c/stdin"
m4_setup "$m4c" $((MOCK_PORT_BASE + 972))
m4_run "$m4c" $((MOCK_PORT_BASE + 972)) "$m4c/stdin" CFW_RENDER_TEST_NO_ENGINE=1
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
if [[ "$m4_rc" == "3" ]] && grep -q '"step": "checking", "state": "failed".*"action": "Sign in to ChatGPT or Claude in AI Providers"' "$m4c/out.jsonl"; then
  pass "from-app: no engine → exit 3 with the AI Providers action"
else
  fail "from-app no engine" "rc=$m4_rc out=$(cat "$m4c/out.jsonl")"
fi
rm -rf "$m4c"

echo "=== Case M3-04a-5: adopt — existing key + plist, empty stdin → Already set up ==="
m4d="$(mktemp -d)"
m4_setup "$m4d" $((MOCK_PORT_BASE + 973))
mkdir -p "$m4d/home/.cfw-render" "$m4d/home/Library/LaunchAgents"
printf 'CFW_API_BASE=http://127.0.0.1:%s\nCFW_RENDER_WORKER_KEY=cfw_render_existing0\n' $((MOCK_PORT_BASE + 973)) > "$m4d/home/.cfw-render/cfw-render.env"
: > "$m4d/home/Library/LaunchAgents/com.cfw.render.plist"
: > "$m4d/stdin"
m4_run "$m4d" $((MOCK_PORT_BASE + 973)) "$m4d/stdin"
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
m4d_ready="$(grep -c '"step": "ready", "state": "done", "message": "Already set up"' "$m4d/out.jsonl" 2>/dev/null || true)"
if [[ "$m4_rc" == "0" && "$m4d_ready" == "1" ]] && ! grep -q '"tool": "exchange"' "$m4d/mockstate/calls.jsonl" 2>/dev/null; then
  pass "from-app adopt: one ready 'Already set up', no exchange"
else
  fail "from-app adopt" "rc=$m4_rc out=$(cat "$m4d/out.jsonl") err=$(tail -5 "$m4d/err.log")"
fi
rm -rf "$m4d"

echo "=== Case M3-04a-6: probe never finishes → test_render failed, exit 7 ==="
m4e="$(mktemp -d)"
printf 'cfw_goodkey\n' > "$m4e/stdin"
m4_setup "$m4e" $((MOCK_PORT_BASE + 974)) CFW_MOCK_PROBE_PENDING=999
m4_run "$m4e" $((MOCK_PORT_BASE + 974)) "$m4e/stdin" CFW_RENDER_PROBE_TIMEOUT_SEC=1
kill "$m4_pid" 2>/dev/null; wait "$m4_pid" 2>/dev/null || true
m4e_steps="$(m4_steps "$m4e")"
if [[ "$m4_rc" == "7" && "$m4e_steps" == *"test_render:started test_render:failed" ]]; then
  pass "from-app: probe timeout → test_render failed, exit 7"
else
  fail "from-app probe timeout" "rc=$m4_rc steps=$m4e_steps"
fi
rm -rf "$m4e"

# ── [M3-06a] uninstall + send-logs ─────────────────────────────────────────
# m6_setup <dir> — a fake installed HOME with a render key, logs, outputs and
# a Keychain stub (CFW_RENDER_SECURITY_CMD) holding 3 items.
m6_setup() {
  local d="$1" key="$2"
  mkdir -p "$d/home/.cfw-render" "$d/home/CFW Render/app/bin" "$d/home/CFW Render/logs/runs" \
    "$d/home/CFW Render/outputs/brand" "$d/home/Library/LaunchAgents" "$d/mockstate"
  printf 'CFW_RENDER_MODE=byoa\nCFW_RENDER_WORKER_KEY=%s\nCFW_API_BASE=http://127.0.0.1:1\n' "$key" > "$d/home/.cfw-render/cfw-render.env"
  chmod 600 "$d/home/.cfw-render/cfw-render.env"
  echo '<plist/>' > "$d/home/Library/LaunchAgents/com.cfw.render.plist"
  echo 'kept' > "$d/home/CFW Render/outputs/brand/out.mp4"
  printf 'tick ok key=%s mail me@example.com /Users/alice/x\n' "$key" > "$d/home/CFW Render/logs/cfw-render.log"
  printf 'run %s\n' "$key" > "$d/home/CFW Render/logs/runs/o1.out"
  printf '{"workerVersion":"1"}\n' > "$d/home/.cfw-render/status.json"
  printf 'ts\torder\t%s\n' "$key" > "$d/home/.cfw-render/journal.tsv"
  echo 3 > "$d/keychain"
  cat > "$d/security" <<SEC
#!/usr/bin/env bash
n=\$(cat "$d/keychain"); (( n > 0 )) || exit 44
echo \$((n - 1)) > "$d/keychain"
SEC
  chmod +x "$d/security"
  echo '[]' > "$d/queue.json"
}
# m6_uninstall <dir> <port> [flags...] — sets m6_rc.
m6_uninstall() {
  local d="$1" port="$2"; shift 2
  ( export HOME="$d/home" CFW_RENDER_API_BASE="http://127.0.0.1:$port" CFW_RENDER_SKIP_LAUNCHCTL=1 \
      CFW_RENDER_SECURITY_CMD="$d/security"
    "$REPO_DIR/install/install.sh" --uninstall "$@" > "$d/out.log" 2> "$d/err.log" )
  m6_rc=$?
}

echo "=== Case M3-06a-1: uninstall happy path (outputs kept, revoke once, Keychain emptied) ==="
m6a="$(mktemp -d)"; m6_setup "$m6a" cfw_render_m6akey000
m6a_port=$((MOCK_PORT_BASE + 980))
m6a_pid="$(start_mock "$m6a/queue.json" "$m6a/mockstate" "$m6a_port")"
m6_uninstall "$m6a" "$m6a_port" --yes
kill "$m6a_pid" 2>/dev/null; wait "$m6a_pid" 2>/dev/null || true
m6a_revokes="$(grep -c '"tool": "revoke_this_computer"' "$m6a/mockstate/calls.jsonl" 2>/dev/null || true)"
if [[ "$m6_rc" == "0" && "$m6a_revokes" == "1" && "$(cat "$m6a/keychain")" == "0" \
      && ! -e "$m6a/home/.cfw-render" && ! -e "$m6a/home/CFW Render/app" && ! -e "$m6a/home/CFW Render/logs" \
      && ! -e "$m6a/home/Library/LaunchAgents/com.cfw.render.plist" && -f "$m6a/home/CFW Render/outputs/brand/out.mp4" ]] \
   && ! grep -q "offline" "$m6a/out.log"; then
  pass "uninstall: paths gone, outputs kept, revoke called once, Keychain stub emptied"
else
  fail "uninstall happy path" "rc=$m6_rc revokes=$m6a_revokes kc=$(cat "$m6a/keychain") out=$(cat "$m6a/out.log")"
fi
rm -rf "$m6a"

echo "=== Case M3-06a-2: uninstall --delete-outputs (+ --from-app JSON lines) ==="
m6b="$(mktemp -d)"; m6_setup "$m6b" cfw_render_m6bkey000
m6b_port=$((MOCK_PORT_BASE + 981))
m6b_pid="$(start_mock "$m6b/queue.json" "$m6b/mockstate" "$m6b_port")"
m6_uninstall "$m6b" "$m6b_port" --non-interactive --from-app --delete-outputs
kill "$m6b_pid" 2>/dev/null; wait "$m6b_pid" 2>/dev/null || true
m6b_json="$(python3 -c '
import json, sys
ls = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(all(o["step"] == "uninstall" for o in ls), ls[-1]["state"] if ls else "")' "$m6b/out.log" 2>/dev/null || echo NONJSON)"
if [[ "$m6_rc" == "0" && ! -e "$m6b/home/CFW Render/outputs" && "$m6b_json" == "True done" ]]; then
  pass "uninstall --delete-outputs: outputs gone; --from-app prints only uninstall JSON lines"
else
  fail "uninstall --delete-outputs" "rc=$m6_rc json=$m6b_json"
fi
rm -rf "$m6b"

echo "=== Case M3-06a-3: uninstall offline → exit 0 with the offline line ==="
m6c="$(mktemp -d)"; m6_setup "$m6c" cfw_render_m6ckey000
m6_uninstall "$m6c" $((MOCK_PORT_BASE + 982)) --yes
if [[ "$m6_rc" == "0" && ! -e "$m6c/home/.cfw-render" ]] \
   && grep -q "This computer will show as offline in CFW until you remove it there." "$m6c/out.log"; then
  pass "uninstall offline: exit 0, offline line printed, files removed"
else
  fail "uninstall offline" "rc=$m6_rc out=$(cat "$m6c/out.log")"
fi
rm -rf "$m6c"

echo "=== Case M3-06a-3b: uninstall refuses a CFW_RENDER_HOME outside the home folder (rm -rf guard) ==="
m6g="$(mktemp -d)"; m6_setup "$m6g" cfw_render_m6gkey000
mkdir -p "$m6g/elsewhere/app" "$m6g/elsewhere/logs"
: > "$m6g/elsewhere/app/keep.txt"
( export HOME="$m6g/home" CFW_RENDER_HOME="$m6g/elsewhere" CFW_RENDER_API_BASE="http://127.0.0.1:$((MOCK_PORT_BASE + 985))" \
    CFW_RENDER_SKIP_LAUNCHCTL=1 CFW_RENDER_SECURITY_CMD="$m6g/security"
  "$REPO_DIR/install/install.sh" --uninstall --yes > "$m6g/out.log" 2> "$m6g/err.log" )
m6g_rc=$?
if [[ "$m6g_rc" != "0" && -f "$m6g/elsewhere/app/keep.txt" && -d "$m6g/home/.cfw-render" ]] \
   && grep -q "Not removing files" "$m6g/out.log" "$m6g/err.log"; then
  pass "uninstall guard: a CFW_RENDER_HOME outside HOME is refused, nothing deleted, non-zero exit"
else
  fail "uninstall guard" "rc=$m6g_rc keep=$([[ -f "$m6g/elsewhere/app/keep.txt" ]] && echo yes || echo no) out=$(cat "$m6g/out.log" "$m6g/err.log")"
fi
rm -rf "$m6g"

echo "=== Case M3-06a-4: redactor fixture parity ==="
# Plain files on both sides: the runner sandbox refuses the /dev/fd path that a
# <( ) process substitution hands to diff.
m6_redact_out="$(mktemp)"
python3 "$REPO_DIR/bin/cfw-render-redact.py" < "$REPO_DIR/desktop/src-tauri/tests/fixtures/redact-input.txt" > "$m6_redact_out" 2>&1
m6_redact_diff="$(diff "$m6_redact_out" "$REPO_DIR/desktop/src-tauri/tests/fixtures/redact-expected.txt" 2>&1)"; m6_redact_rc=$?
rm -f "$m6_redact_out"
if [[ "$m6_redact_rc" == 0 ]]; then
  pass "cfw-render-redact.py output == redact-expected.txt"
else
  fail "redactor parity" "diff vs redact-expected.txt (rc=$m6_redact_rc): $(printf '%s\n' "$m6_redact_diff" | head -6 | tr '\n' '|')"
fi

echo "=== Case M3-06a-5: send-logs uploads, LOG-TEST, render key never leaks ==="
m6e="$(mktemp -d)"
m6e_key="cfw_render_m6e$(python3 -c 'import secrets;print(secrets.token_hex(8))')"
m6_setup "$m6e" "$m6e_key"
m6e_port=$((MOCK_PORT_BASE + 983))
m6e_pid="$(start_mock "$m6e/queue.json" "$m6e/mockstate" "$m6e_port")"
( for _ in $(seq 1 200); do python3 "$TEST_DIR/stop-owned-tree.py" --arguments "$$"; sleep 0.05; done ) > "$m6e/ps.log" 2>/dev/null &
m6e_ps=$!
( export HOME="$m6e/home" CFW_RENDER_API_BASE="http://127.0.0.1:$m6e_port"
  "$REPO_DIR/bin/cfw-render-ctl.sh" send-logs --yes > "$m6e/out.log" 2> "$m6e/err.log" )
m6e_rc=$?
stop_test_tree "$m6e_ps" || { fail "argv watcher cleanup" "could not stop owned tree"; exit 1; }
kill "$m6e_pid" 2>/dev/null; wait "$m6e_pid" 2>/dev/null || true
mkdir -p "$m6e/x"; tar -xzf "$m6e/mockstate/logs-upload.gz" -C "$m6e/x" 2>/dev/null
if [[ "$m6e_rc" == "0" ]] && grep -q "Reference: LOG-TEST — quote it to CFW support." "$m6e/out.log" \
   && [[ -f "$m6e/x/bundle/logs/cfw-render.log" && -f "$m6e/x/bundle/logs/runs/o1.out" && -f "$m6e/x/bundle/journal.tsv" ]]; then
  pass "send-logs: bundle uploaded (logs, runs, journal), Reference LOG-TEST printed"
else
  fail "send-logs upload" "rc=$m6e_rc out=$(cat "$m6e/out.log") err=$(cat "$m6e/err.log")"
fi
m6e_ps_lines="$(wc -l < "$m6e/ps.log" | tr -d ' ')"
if ! grep -rqF "$m6e_key" "$m6e/x" "$m6e/out.log" "$m6e/err.log" "$m6e/ps.log" "$m6e/mockstate" \
   && grep -q "cfw_render_\[redacted\]" "$m6e/x/bundle/logs/cfw-render.log" && grep -q "/Users/\[user\]/" "$m6e/x/bundle/logs/cfw-render.log"; then
  pass "send-logs: render key nowhere (bundle, stdout, stderr, mock log, argv over $m6e_ps_lines ps lines)"
else
  fail "send-logs key leak" "key found or bundle not redacted"
fi
rm -rf "$m6e"

echo "=== Case M3-06a-6: send-logs --dry writes the bundle path, no upload; server down → non-zero ==="
m6f="$(mktemp -d)"; m6_setup "$m6f" cfw_render_m6fkey000
( export HOME="$m6f/home" CFW_RENDER_API_BASE="http://127.0.0.1:$((MOCK_PORT_BASE + 984))" TMPDIR="$m6f"
  "$REPO_DIR/bin/cfw-render-ctl.sh" send-logs --dry > "$m6f/dry.log" 2>&1 )
m6f_dry=$?
m6f_path="$(sed -n 's/^path: //p' "$m6f/dry.log")"
( export HOME="$m6f/home" CFW_RENDER_API_BASE="http://127.0.0.1:$((MOCK_PORT_BASE + 984))"
  "$REPO_DIR/bin/cfw-render-ctl.sh" send-logs --yes > "$m6f/up.log" 2>&1 )
m6f_up=$?
if [[ "$m6f_dry" == "0" && -s "$m6f_path" && "$m6f_up" != "0" ]] && grep -q "could not reach CFW" "$m6f/up.log"; then
  pass "send-logs --dry: path written, nothing sent; offline upload exits non-zero with a plain message"
else
  fail "send-logs dry/offline" "dry=$m6f_dry path=$m6f_path up=$m6f_up $(cat "$m6f/up.log")"
fi
rm -rf "$m6f"

# ===========================================================================
# [M3-08b] more engines: gemini + API-key providers, credit limits
# ===========================================================================
# m8_keychain <dir> <engine=key>... — a `security` stub; items live in <dir>/kc/<account>.
m8_keychain() {
  local d="$1"; shift
  mkdir -p "$d/kc"
  for kv in "$@"; do printf '%s' "${kv#*=}" > "$d/kc/${kv%%=*}"; done
  cat > "$d/security" <<SEC
#!/usr/bin/env bash
acct=""; w=0
while (( \$# )); do case "\$1" in -a) acct="\$2"; shift ;; -w) w=1 ;; esac; shift; done
[[ -n "\$acct" && -f "$d/kc/\$acct" ]] || exit 44
(( w )) && cat "$d/kc/\$acct"
exit 0
SEC
  chmod +x "$d/security"
}
m8_json() { CFW_RENDER_STATE_DIR="$1/cr-state" CFW_RENDER_SECURITY_CMD="$1/security" CFW_RENDER_ENGINE_CMD="$TEST_DIR/fake-engine.sh" \
  bash -c 'cr_log(){ :; }; source "$1/bin/cfw-render-engine.sh"; cr_engines_json' _ "$REPO_DIR"; }

echo "=== Case M3-08b-1: cr_engines_json lists 8 engines with label/auth; Keychain zai item → only zai (of the key engines) signed in ==="
m8a="$(mktemp -d)"; mkdir -p "$m8a/cr-state"; m8_keychain "$m8a" zai=k-zai-000
m8a_out="$(m8_json "$m8a" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join("%s/%s/%s/%s" % (e["name"], e["label"], e["auth"], "Y" if e["signedIn"] else "n") for e in d))')"
m8a_want="codex/ChatGPT/signin/Y claude-code/Claude/signin/Y gemini/Gemini/api_key/n zai/Z.AI/api_key/Y moonshot/Moonshot/api_key/n minimax/MiniMax/api_key/n xai/xAI/api_key/n openrouter/OpenRouter/api_key/n"
if [[ "$m8a_out" == "$m8a_want" ]]; then
  pass "engines json: 8 engines, labels + auth, zai signedIn via Keychain only"
else
  fail "engines json" "got '$m8a_out'"
fi
rm -rf "$m8a"

echo "=== Case M3-08b-2: step on zai → temp CODEX_HOME under the request, key only in engine env, ~/.codex untouched ==="
m8b="$(mktemp -d)"; m8b_key="zai-secret-$RANDOM-$RANDOM"
m8_keychain "$m8b" "zai=$m8b_key"
mkdir -p "$m8b/home/.codex"; echo planted > "$m8b/home/.codex/marker"
# The fake HOME hides the real Playwright cache from preflight: point at it.
m8b_pw="${PLAYWRIGHT_BROWSERS_PATH:-}"
for r in "$HOME/Library/Caches/ms-playwright" "$HOME/.cache/ms-playwright"; do [[ -z "$m8b_pw" && -d "$r" ]] && m8b_pw="$r"; done
c21_setup "$m8b" $((MOCK_PORT_BASE + 990)) harness-3step '[{"id":"o1"}]'
c21_worker "$m8b" $((MOCK_PORT_BASE + 990)) --once CFW_RENDER_ENGINE=zai CFW_RENDER_SECURITY_CMD="$m8b/security" \
  FAKE_ENGINE_DUMP_DIR="$m8b/dump" HOME="$m8b/home" PLAYWRIGHT_BROWSERS_PATH="$m8b_pw"
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m8b_ev="$(c21_events_for "$m8b/control/reports.ndjson" o1)"
m8b_ch="$(cat "$m8b/dump/zai.codexhome" 2>/dev/null)"
m8b_ok=1; m8b_why=""
[[ "$m8b_ev" == *"attempt_completed:-"* ]] || { m8b_ok=0; m8b_why+=" not-completed"; }
[[ "$m8b_ch" == "$m8b/cr-scratch/"*"/.codex-home-zai" ]] || { m8b_ok=0; m8b_why+=" codexhome=$m8b_ch"; }
[[ -n "$m8b_ch" && ! -e "$m8b_ch" ]] || { m8b_ok=0; m8b_why+=" codexhome-left"; }
grep -qx 'model_provider = "zai"' "$m8b/dump/zai.config.toml" 2>/dev/null && [[ "$(grep -c '^\[model_providers\.' "$m8b/dump/zai.config.toml")" == 1 ]] || { m8b_ok=0; m8b_why+=" config"; }
grep -qxF "ZAI_API_KEY=$m8b_key" "$m8b/dump/zai.env" 2>/dev/null || { m8b_ok=0; m8b_why+=" key-not-in-env"; }
grep -qF "$m8b_key" "$m8b/dump/zai.argv" 2>/dev/null && { m8b_ok=0; m8b_why+=" key-in-argv"; }
grep -qxF "model_provider=zai" "$m8b/dump/zai.argv" 2>/dev/null || { m8b_ok=0; m8b_why+=" no-c-flag"; }
grep -rqF "$m8b_key" "$m8b/cr-state" "$m8b/worker.out" "$m8b/control" "$m8b/mockstate" 2>/dev/null && { m8b_ok=0; m8b_why+=" key-leaked"; }
[[ "$(cat "$m8b/home/.codex/marker")" == planted && "$(ls -A "$m8b/home/.codex")" == marker ]] || { m8b_ok=0; m8b_why+=" home-codex-touched"; }
if (( m8b_ok )); then
  pass "zai step: CODEX_HOME under request (removed after), one provider table, key only as ZAI_API_KEY in engine env, ~/.codex untouched"
else
  fail "zai step" "$m8b_why ev='$m8b_ev'"
fi
rm -rf "$m8b"

echo "=== Case M3-08b-3: apikey-429 → zai limited ~15 min, step fails over to codex ==="
m8c="$(mktemp -d)"; m8_keychain "$m8c" zai=k-zai-c
c21_setup "$m8c" $((MOCK_PORT_BASE + 991)) harness-3step '[{"id":"o1"}]'
echo '{"order":["zai","codex","claude-code"]}' > "$m8c/cr-state/engines.json"
c21_worker "$m8c" $((MOCK_PORT_BASE + 991)) --once CFW_RENDER_SECURITY_CMD="$m8c/security" FAKE_ENGINE_LIMIT_ENGINE=zai FAKE_ENGINE_LIMIT_STEP=a
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m8c_started="$(m3b_started "$m8c" o1)"
m8c_min="$(python3 -c '
import json, sys, datetime
u = json.load(open(sys.argv[1]))["zai"]["until"]
t = datetime.datetime.fromisoformat(u.replace("Z", "+00:00"))
print(round((t - datetime.datetime.now(datetime.timezone.utc)).total_seconds() / 60))' "$m8c/cr-state/engine-limits.json" 2>/dev/null)"
if [[ "$m8c_started" == "a:zai a:codex "* && "$m8c_min" =~ ^1[45]$ ]]; then
  pass "apikey 429: zai limited ${m8c_min} min, failover a:zai → a:codex"
else
  fail "apikey 429" "started='$m8c_started' min='$m8c_min'"
fi
rm -rf "$m8c"

echo "=== Case M3-08b-4: apikey-credit → limited with resetsAt null + reason credit, never expires, clear-limit clears ==="
m8d="$(mktemp -d)"; m8_keychain "$m8d" zai=k-zai-d
c21_setup "$m8d" $((MOCK_PORT_BASE + 992)) harness-3step '[{"id":"o1"}]'
echo '{"order":["zai","codex","claude-code"]}' > "$m8d/cr-state/engines.json"
c21_worker "$m8d" $((MOCK_PORT_BASE + 992)) --once CFW_RENDER_SECURITY_CMD="$m8d/security" FAKE_ENGINE_LIMIT_ENGINE=zai FAKE_ENGINE_LIMIT_STEP=a FAKE_ENGINE_APIKEY_FIXTURE=credit
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m8d_started="$(m3b_started "$m8d" o1)"
m8d_file="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("zai")))' "$m8d/cr-state/engine-limits.json" 2>/dev/null)"
m8d_row="$(m8_json "$m8d" | python3 -c '
import json, sys
e = [x for x in json.load(sys.stdin) if x["name"] == "zai"][0]
print(e["limit"], e.get("resetsAt", "missing"), e.get("reason"))')"
# A credit entry carries no timestamp: plant one with an old timestamp too — still limited.
python3 -c 'import json,sys; json.dump({"zai":{"until":"2000-01-01T00:00:00Z","reason":"credit"}}, open(sys.argv[1],"w"))' "$m8d/cr-state/engine-limits.json"
m8d_old="$(m8_json "$m8d" | python3 -c 'import json,sys; print([x for x in json.load(sys.stdin) if x["name"]=="zai"][0]["limit"])')"
CFW_RENDER_STATE_DIR="$m8d/cr-state" "$REPO_DIR/bin/cfw-render-ctl.sh" clear-limit zai > /dev/null 2>&1; m8d_clr=$?
m8d_after="$(m8_json "$m8d" | python3 -c 'import json,sys; print([x for x in json.load(sys.stdin) if x["name"]=="zai"][0]["limit"])')"
if [[ "$m8d_started" == "a:zai a:codex "* && "$m8d_file" == '{"until": null, "reason": "credit"}' && "$m8d_row" == "limited None credit" \
      && "$m8d_old" == limited && "$m8d_clr" == 0 && "$m8d_after" == ok ]]; then
  pass "apikey credit: {until:null,reason:credit}, limited/resetsAt null, survives old timestamp, clear-limit → ok"
else
  fail "apikey credit" "started='$m8d_started' file='$m8d_file' row='$m8d_row' old=$m8d_old clr=$m8d_clr after=$m8d_after"
fi
rm -rf "$m8d"

echo "=== Case M3-08b-4b: ordinary output that mentions credit, billing, 402 or 429 never trips a limit ==="
m8n="$(mktemp -d)"; mkdir -p "$m8n/st"
cat > "$m8n/ok.log" <<'EOF2'
Added a credit line to the end card: "Photo credit: Priya".
Billing page screenshot cropped; 402 frames rendered at 1080x1920.
Scene 3 of 429 total keyframes encoded.
Done. Captions mention the store credit offer.
EOF2
m8n_out=""
for m8n_eng in zai gemini; do
  if m8n_r="$(m3b_detect "$m8n/st" "$m8n_eng" "$m8n/ok.log" 1)"; then m8n_out+="$m8n_eng:$m8n_r "; fi
done
m8n_credit="$(m3b_detect "$m8n/st" zai "$REPO_DIR/test/fixtures/engine-limits/apikey-credit.txt" 1)"
m8n_429="$(m3b_detect "$m8n/st" zai "$REPO_DIR/test/fixtures/engine-limits/apikey-429.txt" 1)"
m8n_gq="$(m3b_detect "$m8n/st" gemini "$REPO_DIR/test/fixtures/engine-limits/gemini-quota.txt" 1)"
if [[ -z "$m8n_out" && "$m8n_credit" == credit && "$m8n_429" == 20* && "$m8n_gq" == 20* ]]; then
  pass "limit detect: ordinary 'credit'/'billing'/'402'/'429' output trips nothing; real vendor credit/429/quota replies still do"
else
  fail "limit detect false positives" "ordinary=[$m8n_out] credit=[$m8n_credit] 429=[$m8n_429] gemini=[$m8n_gq]"
fi
rm -rf "$m8n"

echo "=== Case M3-08b-5: gemini with a Keychain key → GEMINI_API_KEY only in the gemini process env ==="
m8e="$(mktemp -d)"; m8e_key="gem-secret-$RANDOM-$RANDOM"; m8_keychain "$m8e" "gemini=$m8e_key"
c21_setup "$m8e" $((MOCK_PORT_BASE + 993)) harness-3step '[{"id":"o1"}]'
c21_worker "$m8e" $((MOCK_PORT_BASE + 993)) --once CFW_RENDER_ENGINE=gemini CFW_RENDER_SECURITY_CMD="$m8e/security" FAKE_ENGINE_DUMP_DIR="$m8e/dump"
kill "$c21_pid" 2>/dev/null; wait "$c21_pid" 2>/dev/null
m8e_ev="$(c21_events_for "$m8e/control/reports.ndjson" o1)"
if [[ "$m8e_ev" == *"attempt_completed:-"* ]] && grep -qxF "GEMINI_API_KEY=$m8e_key" "$m8e/dump/gemini.env" \
   && grep -qx -- "-p" "$m8e/dump/gemini.argv" && ! grep -qF "$m8e_key" "$m8e/dump/gemini.argv" \
   && ! grep -rqF "$m8e_key" "$m8e/cr-state" "$m8e/worker.out" "$m8e/control" "$m8e/mockstate"; then
  pass "gemini: -p, key only as GEMINI_API_KEY in the engine env, nowhere else"
else
  fail "gemini key" "ev='$m8e_ev' $(cat "$m8e/dump/gemini.argv" 2>/dev/null | tr '\n' ' ')"
fi
rm -rf "$m8e"
# ── M3-05a: desktop release script + install.sh --from-app --update ──
# No mock server needed (ports MOCK_PORT_BASE + 1000..1009 reserved).
echo "=== Case M3-05a-1: release.sh --dry-run with no secrets prints every step with placeholders ==="
r5a="$(mktemp -d)"
env -i PATH="$PATH" HOME="$r5a" bash "$REPO_DIR/desktop/scripts/release.sh" --dry-run > "$r5a/out.log" 2> "$r5a/err.log"
r5a_rc=$?
r5a_ok=1
for want in "+ codesign --force --options runtime --timestamp --sign \\<APPLE_SIGNING_IDENTITY\\> --deep" \
  "+ xcrun notarytool submit" "--key \\<APPLE_API_KEY_PATH\\> --key-id \\<APPLE_API_KEY_ID\\> --issuer \\<APPLE_API_ISSUER\\>" \
  "+ xcrun stapler staple" "+ hdiutil create" "+ pnpm tauri build --target universal-apple-darwin --bundles app" \
  "+ pnpm tauri signer sign" "latest.json"; do
  grep -qF -- "$want" "$r5a/out.log" || { r5a_ok=0; echo "    missing: $want"; }
done
[[ "$(grep -c 'notarytool submit' "$r5a/out.log")" == "2" && "$(grep -c 'stapler staple' "$r5a/out.log")" == "2" ]] || r5a_ok=0
if [[ "$r5a_rc" == "0" && "$r5a_ok" == "1" ]] && ! grep -qF '"$' "$r5a/out.log" && [[ ! -e "$REPO_DIR/desktop/dist-release/latest.json" || "$(git -C "$REPO_DIR" status --porcelain desktop/src-tauri/resources)" == "" ]]; then
  pass "release.sh --dry-run: exit 0, codesign/notarytool/stapler/hdiutil with placeholders, no \"\$ leakage"
else
  fail "release.sh --dry-run" "rc=$r5a_rc ok=$r5a_ok $(head -c 600 "$r5a/err.log")"
fi

echo "=== Case M3-05a-2: release.sh without secrets refuses (exit 2) and names them ==="
env -i PATH="$PATH" HOME="$r5a" APPLE_API_KEY_ID=present-id bash "$REPO_DIR/desktop/scripts/release.sh" > "$r5a/real.log" 2>&1
r5b_rc=$?
r5b_ok=1
for n in APPLE_SIGNING_IDENTITY APPLE_API_KEY_PATH APPLE_API_ISSUER TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD DESKTOP_RELEASE_BASE_URL; do
  grep -q "$n" "$r5a/real.log" || r5b_ok=0
done
if [[ "$r5b_rc" == "2" && "$r5b_ok" == "1" ]] && ! grep -q "APPLE_API_KEY_ID\|present-id\|codesign" "$r5a/real.log"; then
  pass "release.sh without secrets: exit 2, lists only the missing names, runs nothing"
else
  fail "release.sh missing secrets" "rc=$r5b_rc ok=$r5b_ok $(cat "$r5a/real.log")"
fi

echo "=== Case M3-05c-1: release.sh --unsigned --dry-run needs no secrets, ad-hoc signs, never notarizes or writes the feed ==="
env -i PATH="$PATH" HOME="$r5a" bash "$REPO_DIR/desktop/scripts/release.sh" --unsigned --dry-run > "$r5a/u.log" 2> "$r5a/u.err"
r5c_rc=$?
r5c_ok=1
for want in "UNSIGNED tester build (universal)" "+ cp -a" "+ env APPLE_SIGNING_IDENTITY=- pnpm tauri build --target universal-apple-darwin --bundles app" \
  "+ codesign --force --deep --sign -" "+ codesign --verify --deep --strict" "CFW-Render-" "-unsigned-universal.dmg" "desktop/TESTERS.md"; do
  grep -qF -- "$want" "$r5a/u.log" || { r5c_ok=0; echo "    missing: $want"; }
done
for banned in notarytool stapler "signer sign" "latest.json" "--options runtime" "APPLE_API"; do
  grep -qF -- "$banned" "$r5a/u.log" && { r5c_ok=0; echo "    unexpected: $banned"; }
done
if [[ "$r5c_rc" == "0" && "$r5c_ok" == "1" && ! -s "$r5a/u.err" ]]; then
  pass "release.sh --unsigned --dry-run: exit 0 with no secrets, ad-hoc sign + verify + dmg, no notarize/updater/feed"
else
  fail "release.sh --unsigned --dry-run" "rc=$r5c_rc ok=$r5c_ok $(head -c 600 "$r5a/u.err")"
fi

echo "=== Case M3-05c-2: --target picks the arch for tester builds; bad or signed-mode --target refuses ==="
env -i PATH="$PATH" HOME="$r5a" bash "$REPO_DIR/desktop/scripts/release.sh" --unsigned --target aarch64-apple-darwin --dry-run > "$r5a/a.log" 2>&1
r5d_rc=$?
env -i PATH="$PATH" HOME="$r5a" bash "$REPO_DIR/desktop/scripts/release.sh" --unsigned --target 'x;touch pwned' --dry-run > "$r5a/bad.log" 2>&1
r5e_rc=$?
env -i PATH="$PATH" HOME="$r5a" bash "$REPO_DIR/desktop/scripts/release.sh" --target aarch64-apple-darwin --dry-run > "$r5a/signed.log" 2>&1
r5f_rc=$?
if [[ "$r5d_rc" == "0" && "$r5e_rc" == "2" && "$r5f_rc" == "2" ]] \
  && grep -qF -- "--target aarch64-apple-darwin --bundles app" "$r5a/a.log" \
  && grep -qF -- "target/aarch64-apple-darwin/release/bundle/macos" "$r5a/a.log" \
  && grep -qF -- "-unsigned-apple-silicon.dmg" "$r5a/a.log" \
  && grep -q "unsupported --target" "$r5a/bad.log" && ! grep -q "codesign\|hdiutil" "$r5a/bad.log" \
  && grep -q "only for --unsigned" "$r5a/signed.log" && ! grep -q "codesign\|hdiutil" "$r5a/signed.log"; then
  pass "release.sh --target: aarch64 → apple-silicon dmg; unknown target and signed-mode --target exit 2 and run nothing"
else
  fail "release.sh --target" "rc=$r5d_rc/$r5e_rc/$r5f_rc $(head -c 400 "$r5a/bad.log") $(head -c 300 "$r5a/signed.log")"
fi
rm -rf "$r5a"

echo "=== Case M3-05a-3: install.sh --from-app --update refreshes CFW Render/app, prints Updated, reads no stdin ==="
r5c="$(mktemp -d)"
mkdir -p "$r5c/home/CFW Render/app/bin" "$r5c/home/CFW Render/app/config"
printf 'stale\n' > "$r5c/home/CFW Render/app/bin/cfw-render.sh"
printf 'local\n' > "$r5c/home/CFW Render/app/config/local-only.json"
printf 'KEEP-THIS-LINE\n' > "$r5c/stdin"
( export HOME="$r5c/home" CFW_RENDER_SKIP_LAUNCHCTL=1
  { "$REPO_DIR/install/install.sh" --mode byoa --non-interactive --from-app --update > "$r5c/out.jsonl" 2> "$r5c/err.log"
    echo "rc=$?" > "$r5c/rc"; cat > "$r5c/rest"; } < "$r5c/stdin" )
if [[ "$(cat "$r5c/rc")" == "rc=0" && "$(cat "$r5c/out.jsonl")" == '{"step": "ready", "state": "done", "message": "Updated"}' ]] \
   && cmp -s "$REPO_DIR/bin/cfw-render.sh" "$r5c/home/CFW Render/app/bin/cfw-render.sh" \
   && cmp -s "$REPO_DIR/VERSION" "$r5c/home/CFW Render/app/VERSION" \
   && [[ -f "$r5c/home/CFW Render/app/config/local-only.json" && "$(cat "$r5c/rest")" == "KEEP-THIS-LINE" ]]; then
  pass "install.sh --update: changed file refreshed, local config kept, one Updated line, stdin untouched"
else
  fail "install.sh --update" "$(cat "$r5c/rc") out=$(cat "$r5c/out.jsonl") rest=$(cat "$r5c/rest") $(head -c 400 "$r5c/err.log")"
fi
rm -rf "$r5c"

echo "=== Case M3-05a-4: --update reloads the worker even when launchd refuses the first bootstrap; a worker that never loads is reported ==="
r5d="$(mktemp -d)"
mkdir -p "$r5d/home/CFW Render/app/bin" "$r5d/home/Library/LaunchAgents" "$r5d/bin"
printf '<plist/>\n' > "$r5d/home/Library/LaunchAgents/com.cfw.render.plist"
# Fake launchctl: logs every call; bootstrap fails while $r5d/fail-left > 0.
cat > "$r5d/bin/launchctl" <<'EOF_LC'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")/.." && pwd)"
echo "$*" >> "$d/launchctl.log"
if [[ "$1" == "bootstrap" ]]; then
  n="$(cat "$d/fail-left" 2>/dev/null || echo 0)"
  if (( n > 0 )); then echo $((n - 1)) > "$d/fail-left"; echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi
  touch "$d/loaded"
fi
exit 0
EOF_LC
chmod +x "$r5d/bin/launchctl"
r5d_run() { ( export HOME="$r5d/home" PATH="$r5d/bin:$PATH" CFW_RENDER_BOOTSTRAP_WAIT_SEC=0 CFW_RENDER_BOOTSTRAP_TRIES=3
  "$REPO_DIR/install/install.sh" --mode byoa --non-interactive --from-app --update > "$r5d/out.jsonl" 2> "$r5d/err.log" < /dev/null
  echo "$?" > "$r5d/rc" ); }
echo 1 > "$r5d/fail-left"; r5d_run
r5d_a_rc="$(cat "$r5d/rc")"; r5d_a_out="$(cat "$r5d/out.jsonl")"
r5d_a_boots="$(grep -c '^bootstrap' "$r5d/launchctl.log" 2>/dev/null)"; r5d_a_loaded=0; [[ -f "$r5d/loaded" ]] && r5d_a_loaded=1
rm -f "$r5d/launchctl.log" "$r5d/loaded"; echo 99 > "$r5d/fail-left"; r5d_run
r5d_b_rc="$(cat "$r5d/rc")"; r5d_b_out="$(cat "$r5d/out.jsonl")"; r5d_b_boots="$(grep -c '^bootstrap' "$r5d/launchctl.log" 2>/dev/null)"
if [[ "$r5d_a_rc" == "0" && "$r5d_a_out" == '{"step": "ready", "state": "done", "message": "Updated"}' && "$r5d_a_boots" == "2" && "$r5d_a_loaded" == "1" ]]; then
  pass "install.sh --update: first bootstrap refused (I/O error) → retried, worker loaded, Updated"
else
  fail "install.sh --update bootstrap retry" "rc=$r5d_a_rc boots=$r5d_a_boots loaded=$r5d_a_loaded out=$r5d_a_out"
fi
if [[ "$r5d_b_rc" == "6" && "$r5d_b_boots" == "3" ]] && grep -q '"state": "failed"' <<< "$r5d_b_out" && ! grep -q '"message": "Updated"' <<< "$r5d_b_out"; then
  pass "install.sh --update: a worker that never loads is reported as failed (exit 6), never 'Updated'"
else
  fail "install.sh --update never-loads" "rc=$r5d_b_rc boots=$r5d_b_boots out=$r5d_b_out"
fi
rm -rf "$r5d"

echo "=== Case 37: carousel render.mjs loads Playwright from the work folder (WI2.38) ==="
# The step runs `node "$SKILL_DIR/render.mjs"` with cwd = work/, after installing
# Playwright into work/node_modules. The skill folder itself has no node_modules.
# Before the loader, Node reported ERR_MODULE_NOT_FOUND from the script path.
wi238="$(mktemp -d)"
wi238_skill="$wi238/skill"
wi238_work="$wi238/work"
mkdir -p "$wi238_skill" "$wi238_work/node_modules/playwright"
cp "$REPO_DIR/skills/p-carousel/render.mjs" "$wi238_skill/render.mjs"
if [[ ! -e "$wi238_skill/node_modules" ]]; then
  pass "render.mjs resolution: skill folder has no node_modules"
else
  fail "render.mjs resolution: skill node_modules" "the skill folder must not supply playwright"
fi
cat > "$wi238_work/node_modules/playwright/package.json" <<'EOF'
{
  "name": "playwright",
  "version": "0.0.0",
  "type": "module",
  "main": "index.js",
  "exports": { ".": "./index.js" }
}
EOF
cat > "$wi238_work/node_modules/playwright/index.js" <<'EOF'
export const chromium = {
  launch() {
    throw new Error("WI238_PLAYWRIGHT_FROM_WORK");
  },
};
EOF
wi238_out="$(
  cd "$wi238_work" && SCALE=1 node "$wi238_skill/render.mjs" carousel.html 2>&1 || true
)"
if [[ "$wi238_out" == *WI238_PLAYWRIGHT_FROM_WORK* && "$wi238_out" != *ERR_MODULE_NOT_FOUND* ]]; then
  pass "render.mjs resolves the work-folder playwright stub when run from work"
else
  fail "render.mjs work-folder playwright" "${wi238_out:0:700}"
fi

wi238_miss="$(mktemp -d)"
mkdir -p "$wi238_miss/skill" "$wi238_miss/work"
cp "$REPO_DIR/skills/p-carousel/render.mjs" "$wi238_miss/skill/render.mjs"
wi238_miss_out="$(
  cd "$wi238_miss/work" && SCALE=1 node "$wi238_miss/skill/render.mjs" carousel.html 2>&1 || true
)"
if [[ "$wi238_miss_out" == *"/work/node_modules/playwright"* \
   && "$wi238_miss_out" == *"/skill/node_modules/playwright"* \
   && "$wi238_miss_out" == *"Cannot find package 'playwright'"* \
   && "$wi238_miss_out" != *ERR_MODULE_NOT_FOUND* ]]; then
  pass "render.mjs names the work folder and the script folder when playwright is missing"
else
  fail "render.mjs missing playwright" "${wi238_miss_out:0:700}"
fi

# Re-sync must keep the loader. The fixture source has no render.mjs, so plant
# the pre-fix import block into a copy and let sync-skills.py rewrite it.
wi238_src="$(mktemp -d)"
cp -R "$TEST_DIR/fixtures/skills-src/." "$wi238_src/"
python3 - "$REPO_DIR/skills/p-carousel/render.mjs" "$wi238_src/p-fixture-recipe/render.mjs" <<'PY'
import pathlib, sys
fixed = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
start = fixed.index("import { createRequire } from 'node:module';\n")
end = fixed.index("const HTML")
static = (
    "import { chromium } from 'playwright';\n"
    "import { mkdir } from 'node:fs/promises';\n"
    "import { execFileSync } from 'node:child_process';\n"
    "\n"
)
pathlib.Path(sys.argv[2]).write_text(fixed[:start] + static + fixed[end:], encoding="utf-8")
PY
wi238_sync="$(mktemp -d)"
wi238_sync_rc=0
wi238_sync_log="$(
  CFW_SKILLS_SRC="$wi238_src" "$REPO_DIR/scripts/sync-skills.sh" \
    --recipes "$TEST_DIR/fixtures/fixture-recipes.json" --out-dir "$wi238_sync" --skip-manifest 2>&1
)" || wi238_sync_rc=$?
if [[ "$wi238_sync_rc" == "0" ]] && cmp -s "$REPO_DIR/skills/p-carousel/render.mjs" "$wi238_sync/p-fixture-recipe/render.mjs"; then
  pass "sync-skills.py keeps the work-folder Playwright loader on re-sync"
else
  wi238_diff="$(diff -u "$REPO_DIR/skills/p-carousel/render.mjs" "$wi238_sync/p-fixture-recipe/render.mjs" 2>&1 || true)"
  fail "sync-skills.py playwright loader" "rc=$wi238_sync_rc diff=${wi238_diff:0:500} log=${wi238_sync_log:0:400}"
fi
rm -rf "$wi238" "$wi238_miss" "$wi238_src" "$wi238_sync"

echo "=== Case 38: manifest completion sees settings-file worker values, and a failed hand-off blocks (WI2.40) ==="
# The smoke ran the worker with these three unset in the process and present
# only as plain assignments in the CFW_RENDER_ENV file. cr_load_config sources
# that file. The step subshell exports them; the completion subshell must too.
wi240_key="cfw_render_wi240fileonly0000"
wi240_worker_id="w-wi240-file"
wi240_link_bin() {
  local dest="$1"
  rm -rf "$dest"
  mkdir -p "$dest"
  local f base
  for f in "$REPO_DIR/bin/"*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$base" == "cfw-render-report.sh" ]] && continue
    cp "$f" "$dest/$base"
  done
  cat > "$dest/cfw-render-report.sh" <<'EOF'
#!/usr/bin/env bash
# Test stand-in placed where the completion subshell finds cfw-render-report.sh.
# Records the three worker settings (never the key value) then runs the real script.
set -u
rec="${CFW_WI240_RECORD:?}"
verb="${1:-}"
{
  printf 'verb=%s\n' "$verb"
  printf 'api=%s\n' "${CFW_API_BASE:-}"
  printf 'worker=%s\n' "${CFW_WORKER_ID:-}"
  if [[ -n "${CFW_RENDER_WORKER_KEY:-}" && "${CFW_RENDER_WORKER_KEY}" == "${CFW_WI240_EXPECT_KEY:-}" ]]; then
    printf 'key=match\n'
  else
    printf 'key=absent\n'
  fi
} >> "$rec"
if [[ "$verb" == "complete" && "${CFW_WI240_FAIL_COMPLETE:-}" == "1" ]]; then
  exit 1
fi
exec "${CFW_WI240_REAL_REPORT:?}" "$@"
EOF
  chmod +x "$dest/cfw-render-report.sh"
}
wi240_field() {
  python3 -c '
import sys
want, key = sys.argv[2], sys.argv[3]
cur = {}
found = None
def take():
    global found
    if cur.get("verb") == want:
        found = dict(cur)
for line in open(sys.argv[1]):
    k, sep, v = line.strip().partition("=")
    if not sep:
        continue
    if k == "verb" and cur:
        take()
        cur = {}
    cur[k] = v
take()
print("" if found is None else found.get(key, ""))
' "$1" "$2" "$3"
}
wi240_worker() {
  local dir="$1" port="$2" fail_complete="$3"
  local settings="$dir/settings.env" record="$dir/report-env.txt"
  wi240_link_bin "$dir/bin"
  printf 'CFW_API_BASE=http://127.0.0.1:%s\nCFW_WORKER_ID=%s\nCFW_RENDER_WORKER_KEY=%s\n' \
    "$port" "$wi240_worker_id" "$wi240_key" > "$settings"
  chmod 600 "$settings"
  : > "$record"
  (
    unset CFW_API_BASE CFW_WORKER_ID CFW_RENDER_WORKER_KEY
    export CFW_RENDER_ENV="$settings"
    export CFW_RENDER_TEST_MEDIA_BASE_URL="http://127.0.0.1:$port"
    export CFW_RENDER_STATE_DIR="$dir/cr-state"
    export CFW_RENDER_LOG_DIR="$dir/cr-state"
    export CFW_RENDER_KEEP_OUTPUTS=0
    export CFW_RENDER_SCRATCH="$dir/cr-scratch"
    export CFW_RENDER_SKILLS_DIR="$dir/skills"
    export CFW_RENDER_OLLAMA_KEYS_FILE="$OLLAMA_KEYS_FIXTURE"
    export CFW_RENDER_DIRECTOR_CMD="$TEST_DIR/fake-director.sh"
    export CFW_RENDER_ENGINE_CMD="$TEST_DIR/fake-engine.sh"
    export CFW_RENDER_HEARTBEAT_SEC=1
    export CFW_RENDER_HEARTBEAT_SECS=0
    export CFW_RENDER_CONCURRENCY=1
    export CFW_RENDER_UPLOAD_MODE=multipart
    export CFW_WI240_RECORD="$record"
    export CFW_WI240_EXPECT_KEY="$wi240_key"
    export CFW_WI240_REAL_REPORT="$REPO_DIR/bin/cfw-render-report.sh"
    export CFW_WI240_FAIL_COMPLETE="$fail_complete"
    "$dir/bin/cfw-render.sh" > "$dir/worker.out" 2>&1
  )
}
wi240_leaked() {
  local dir="$1"
  grep -qF "$wi240_key" "$dir/worker.out" "$dir/report-env.txt" "$dir/cr-state/cfw-render.log" "$dir/mockstate/calls.jsonl" 2>/dev/null
}
wi240_hint() {
  python3 -c '
import pathlib, sys
key, path = sys.argv[1], sys.argv[2]
file = pathlib.Path(path)
text = file.read_text(errors="replace")[-400:] if file.is_file() else ""
print(text.replace(key, "[key]").replace("\n", " | ")[-300:])
' "$wi240_key" "$1"
}

echo "--- 38a: completion report receives the three values from the settings file only"
wi240a="$(mktemp -d)"
wi240a_port=$((MOCK_PORT_BASE + 1010))
c19_setup "$wi240a" "$wi240a_port"
wi240_worker "$wi240a" "$wi240a_port" 0
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
wi240a_api="$(wi240_field "$wi240a/report-env.txt" complete api)"
wi240a_wid="$(wi240_field "$wi240a/report-env.txt" complete worker)"
wi240a_key="$(wi240_field "$wi240a/report-env.txt" complete key)"
wi240a_call="$(python3 -c '
import json, sys
want_id, want_worker = sys.argv[1], sys.argv[2]
n = 0
ok = False
for line in open(sys.argv[3]):
    d = json.loads(line)
    if d.get("tool") != "complete_render_order":
        continue
    n += 1
    a = d.get("args") or {}
    if d.get("ok") is True and a.get("orderId") == want_id and a.get("workerId") == want_worker:
        ok = True
print("ok" if ok and n == 1 else "n=%s ok=%s" % (n, ok))
' "order-h1" "$wi240_worker_id" "$wi240a/mockstate/calls.jsonl" 2>/dev/null || echo "parse-error")"
if [[ "$wi240a_api" == "http://127.0.0.1:$wi240a_port" && "$wi240a_wid" == "$wi240_worker_id" && "$wi240a_key" == "match" && "$wi240a_call" == "ok" ]] && ! wi240_leaked "$wi240a"; then
  pass "completion report: CFW_API_BASE, CFW_WORKER_ID and CFW_RENDER_WORKER_KEY come from the settings file"
else
  fail "completion report settings file" "api='$wi240a_api' worker='$wi240a_wid' keyflag='$wi240a_key' call='$wi240a_call' log=$(wi240_hint "$wi240a/worker.out")"
fi
rm -rf "$wi240a"

echo "--- 38b: a failed completion blocks the order instead of only logging"
wi240b="$(mktemp -d)"
wi240b_port=$((MOCK_PORT_BASE + 1011))
c19_setup "$wi240b" "$wi240b_port"
wi240_worker "$wi240b" "$wi240b_port" 1
kill "$c19_pid" 2>/dev/null; wait "$c19_pid" 2>/dev/null
wi240b_block="$(python3 -c '
import json, sys
want_id, want_worker, want_reason = sys.argv[1], sys.argv[2], sys.argv[3]
blocked = False
completed = 0
for line in open(sys.argv[4]):
    d = json.loads(line)
    if d.get("tool") == "complete_render_order":
        completed += 1
    if d.get("tool") != "block_render_order":
        continue
    a = d.get("args") or {}
    if d.get("ok") is True and a.get("orderId") == want_id and a.get("workerId") == want_worker and a.get("reason") == want_reason:
        blocked = True
print("ok" if blocked and completed == 0 else "blocked=%s completed=%s" % (blocked, completed))
' "order-h1" "$wi240_worker_id" "could not hand off the finished render" "$wi240b/mockstate/calls.jsonl" 2>/dev/null || echo "parse-error")"
wi240b_journal=0
grep -q $'\tfailed\t' "$wi240b/cr-state/journal.tsv" 2>/dev/null && wi240b_journal=1
wi240b_api="$(wi240_field "$wi240b/report-env.txt" block api)"
wi240b_wid="$(wi240_field "$wi240b/report-env.txt" block worker)"
wi240b_key="$(wi240_field "$wi240b/report-env.txt" block key)"
if [[ "$wi240b_block" == "ok" && "$wi240b_journal" == "1" && "$wi240b_api" == "http://127.0.0.1:$wi240b_port" && "$wi240b_wid" == "$wi240_worker_id" && "$wi240b_key" == "match" ]] && ! wi240_leaked "$wi240b"; then
  pass "failed completion: block_render_order with a reason, order not left claimed"
else
  fail "failed completion block" "block='$wi240b_block' journal=$wi240b_journal api='$wi240b_api' worker='$wi240b_wid' keyflag='$wi240b_key' log=$(wi240_hint "$wi240b/worker.out")"
fi
rm -rf "$wi240b"

echo "=== Case 39: p-carousel completion sends N slides in order, never cover/sheet (WI2.43) ==="
# Smoke 10 delivered only cover.png + slide_sheet.png because the harness lists
# every media save and the recipe only declared those two images. The worker must
# select saves/slide_1..slide_N from slides.json instead.
wi243="$(mktemp -d)"
mkdir -p "$wi243/steps/render_slides/saves" "$wi243/steps/captions/saves" "$wi243/bin"
cp "$REPO_DIR/bin/cfw-render-lib.sh" "$wi243/bin/cfw-render-lib.sh"
cp "$REPO_DIR/bin/cfw-render-report.sh" "$wi243/bin/cfw-render-report.sh"
cat > "$wi243/steps/render_slides/saves/slides.json" <<'JSON'
{"width":1080,"height":1350,"count":3,"slides":[{"n":1,"sha256":"a","bytes":1},{"n":2,"sha256":"b","bytes":1},{"n":3,"sha256":"c","bytes":1}]}
JSON
printf 'slide-one' > "$wi243/steps/render_slides/saves/slide_1.png"
printf 'slide-two' > "$wi243/steps/render_slides/saves/slide_2.png"
printf 'slide-three' > "$wi243/steps/render_slides/saves/slide_3.png"
printf 'preview-cover' > "$wi243/steps/render_slides/saves/cover.png"
printf 'preview-sheet' > "$wi243/steps/render_slides/saves/slide_sheet.png"
printf '{"instagram":"Carousel caption","default":"Carousel caption"}' > "$wi243/steps/captions/saves/captions.json"
wi243_h_out="$(python3 -c '
import json, sys
root = sys.argv[1]
print(json.dumps([
  {"id":"cover","path":root+"/steps/render_slides/saves/cover.png"},
  {"id":"slide_sheet","path":root+"/steps/render_slides/saves/slide_sheet.png"},
  {"id":"slides","path":root+"/steps/render_slides/saves/slides.json"},
  {"id":"qa_report","path":root+"/steps/render_slides/saves/qa_report.json"},
  {"id":"captions","path":root+"/steps/captions/saves/captions.json"},
]))
' "$wi243")"
wi243_sel="$(
  # shellcheck disable=SC1091
  source "$wi243/bin/cfw-render-lib.sh"
  cr_select_deliverables "$wi243" "$wi243_h_out"
)"
wi243_sel_check="$(python3 -c '
import os, sys
root = sys.argv[1]
lines = [l for l in sys.argv[2].splitlines() if l.strip()]
want = [
  root + "/steps/render_slides/saves/slide_1.png\tmedia",
  root + "/steps/render_slides/saves/slide_2.png\tmedia",
  root + "/steps/render_slides/saves/slide_3.png\tmedia",
  root + "/steps/captions/saves/captions.json\tcaptions",
]
bad = []
if lines != want:
  bad.append("selected=%r want=%r" % (lines, want))
joined = "\n".join(lines)
if "cover.png" in joined or "slide_sheet.png" in joined:
  bad.append("preview leaked into selection")
print("ok" if not bad else "; ".join(bad))
' "$wi243" "$wi243_sel")"
if [[ "$wi243_sel_check" == "ok" ]]; then
  pass "carousel select: ordered slide_1..slide_3 + captions, no cover/sheet"
else
  fail "carousel select ordered slides" "$wi243_sel_check"
fi

# Missing individual slides with slides.json present must not fall back to previews.
rm -f "$wi243/steps/render_slides/saves/slide_2.png"
wi243_missing="$(
  source "$wi243/bin/cfw-render-lib.sh"
  cr_select_deliverables "$wi243" "$wi243_h_out"
)"
if [[ -z "$wi243_missing" ]]; then
  pass "carousel select: refuses cover/sheet fallback when a slide PNG is missing"
else
  fail "carousel select missing slide" "expected empty, got: $wi243_missing"
fi
printf 'slide-two' > "$wi243/steps/render_slides/saves/slide_2.png"

# Full complete_render_order payload: N slides in order, never cover/sheet.
wi243_calls="$wi243/calls.jsonl"
: > "$wi243_calls"
cat > "$wi243/bin/cfw-render-upload.sh" <<'EOF'
#!/usr/bin/env bash
printf "https://media.cfw.social/%s\n" "$(basename "$1")"
EOF
chmod +x "$wi243/bin/cfw-render-upload.sh"
cp "$REPO_DIR/bin/cfw-render-lib.sh" "$wi243/bin/cfw-render-lib.sh"
cat >> "$wi243/bin/cfw-render-lib.sh" <<EOF
cr_mcp_call() {
  printf '%s\n' "\$2" >> "$wi243_calls"
  printf '{"ok":true}'
}
cr_heartbeat_stop_if_pending() { :; }
EOF
wi243_files=()
wi243_captions=""
while IFS=$'\t' read -r f role; do
  [[ -n "$f" ]] || continue
  if [[ "$role" == "captions" ]]; then wi243_captions="$f"; else wi243_files+=("$f"); fi
done < <(
  # shellcheck disable=SC1091
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_select_deliverables "$wi243" "$wi243_h_out"
)
wi243_complete_err="$wi243/complete.err"
(
  cd "$wi243" || exit 1
  export CFW_ORDER_ID="order-wi243" CFW_WORKER_ID="w-wi243" CFW_ATTEMPT_ID="attempt-wi243"
  export CFW_API_BASE="http://127.0.0.1:9" CFW_RENDER_WORKER_KEY="cfw_render_wi243testkey0000"
  export CFW_RENDER_DIRECTOR_MODEL="sonnet"
  export CFW_CAPTIONS_FILE="${wi243_captions}"
  PATH="$wi243/bin:$PATH"
  bash "$wi243/bin/cfw-render-report.sh" complete "${wi243_files[@]}"
) >"$wi243/complete.out" 2>"$wi243_complete_err"
wi243_payload="$(python3 -c '
import json, pathlib, sys
calls = pathlib.Path(sys.argv[1])
err = pathlib.Path(sys.argv[2]).read_text(errors="replace")[-400:] if pathlib.Path(sys.argv[2]).is_file() else ""
if not calls.is_file() or not calls.read_text().strip():
    print("parse-error: empty calls; stderr=%r" % err.replace("\n", " | "))
    raise SystemExit(0)
rows = [json.loads(l) for l in calls.read_text().splitlines() if l.strip()]
assert len(rows) == 1, rows
d = rows[0]
names = [u.split("/")[-1] for u in d.get("outputUrls", [])]
roles = [o.get("role") for o in d.get("outputs", [])]
bad = []
if names != ["slide_1.png", "slide_2.png", "slide_3.png"]:
  bad.append("names=%r" % names)
if "cover.png" in names or "slide_sheet.png" in names:
  bad.append("preview in outputUrls")
if roles != ["cover", "slide", "slide"]:
  bad.append("roles=%r" % roles)
caps = d.get("captions") or {}
if caps.get("instagram") != "Carousel caption":
  bad.append("captions=%r" % caps)
print("ok" if not bad else "; ".join(bad))
' "$wi243_calls" "$wi243_complete_err" 2>/dev/null || echo "parse-error")"
if [[ "$wi243_payload" == "ok" ]]; then
  pass "carousel complete: N slides in order, roles cover/slide/slide, no cover.png or slide_sheet.png"
else
  fail "carousel complete ordered slides" "$wi243_payload"
fi

# Recipe step still requires ordered slide_N saves (instruction contract).
wi243_recipe_ok=1
grep -q 'saves/slide_1.png' "$REPO_DIR/skills/p-carousel/steps/03-render-slides.md" || wi243_recipe_ok=0
grep -q 'saves/slide_N.png' "$REPO_DIR/skills/p-carousel/steps/03-render-slides.md" || wi243_recipe_ok=0
grep -q 'preview only' "$REPO_DIR/skills/p-carousel/steps/03-render-slides.md" || wi243_recipe_ok=0
grep -q 'cover.png' "$REPO_DIR/skills/p-carousel/SKILL.md" || wi243_recipe_ok=0
grep -q 'slide_sheet.png' "$REPO_DIR/skills/p-carousel/SKILL.md" || wi243_recipe_ok=0
grep -q 'never' "$REPO_DIR/skills/p-carousel/SKILL.md" || grep -qi 'Never' "$REPO_DIR/skills/p-carousel/SKILL.md" || wi243_recipe_ok=0
if [[ "$wi243_recipe_ok" == "1" ]] && grep -q 'slide_N.png' "$REPO_DIR/skills/p-carousel/SKILL.md"; then
  pass "carousel recipe: render_slides saves slide_N; cover/sheet are previews only"
else
  fail "carousel recipe slide_N contract" "03-render-slides.md or SKILL.md missing ordered-slide delivery wording"
fi

# Non-carousel: without slides.json, reel cover.png remains a deliverable.
wi243_reel="$(mktemp -d)"
mkdir -p "$wi243_reel/final"
printf 'video' > "$wi243_reel/final/out.mp4"
printf 'poster' > "$wi243_reel/final/cover.png"
wi243_reel_out="$(
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_select_deliverables "$wi243_reel" "$(python3 -c '
import json, sys
root = sys.argv[1]
print(json.dumps([
  {"id":"video","path":root+"/final/out.mp4"},
  {"id":"cover","path":root+"/final/cover.png"},
]))
' "$wi243_reel")"
)"
if [[ "$wi243_reel_out" == *$'\tmedia'* && "$wi243_reel_out" == *"/final/out.mp4"$'\tmedia'* && "$wi243_reel_out" == *"/final/cover.png"$'\tmedia'* ]]; then
  pass "non-carousel select: reel cover.png stays a deliverable when slides.json is absent"
else
  fail "non-carousel reel cover" "got: $wi243_reel_out"
fi
rm -rf "$wi243_reel"
rm -rf "$wi243"

echo "=== Case 39b: p-gfx-image select keeps image_1, drops preview sheet and final (WI2.51) ==="
# Smoke 12 delivered image_1.png plus contact_sheet.png and final.png. The
# recipe manifest marks contact_sheet and final preview:true. image_1 is the
# graphic and must be the only media line. A result with only those previews
# selects nothing (no fallback). contact_sheet is matched by basename stem
# because that harness item has no id.
wi251="$(mktemp -d)"
mkdir -p "$wi251/steps/render/saves" "$wi251/steps/qa_gate/saves" "$wi251/steps/captions/saves"
printf 'graphic' > "$wi251/steps/render/saves/image_1.png"
printf 'sheet' > "$wi251/steps/render/saves/contact_sheet.png"
printf 'qa-final' > "$wi251/steps/qa_gate/saves/final.png"
printf '{"instagram":"Graphic caption","default":"Graphic caption"}' > "$wi251/steps/captions/saves/captions.json"
python3 - "$wi251/order.json" "$REPO_DIR/skills/p-gfx-image/manifest.json" <<'PY'
import json, sys
dest, man_path = sys.argv[1], sys.argv[2]
man = json.load(open(man_path))
json.dump({
    "id": "order-wi251",
    "recipe": man.get("recipe"),
    "recipeVersion": man.get("recipeVersion"),
    "manifest": man,
}, open(dest, "w"))
PY
wi251_h="$(python3 -c '
import json, sys
root = sys.argv[1]
print(json.dumps([
  {"id": "image_1", "path": root + "/steps/render/saves/image_1.png"},
  {"path": root + "/steps/render/saves/contact_sheet.png"},
  {"id": "final", "path": root + "/steps/qa_gate/saves/final.png"},
  {"id": "captions", "path": root + "/steps/captions/saves/captions.json"},
]))
' "$wi251")"
wi251_sel="$(
  # shellcheck disable=SC1091
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_select_deliverables "$wi251" "$wi251_h"
)"
wi251_sel_check="$(python3 - "$wi251" "$wi251_sel" "$REPO_DIR/skills/p-gfx-image/manifest.json" <<'PY'
import json, os, sys
root, text, man_path = sys.argv[1], sys.argv[2], sys.argv[3]
man = json.load(open(man_path))
flags = {}
for step in man.get("steps") or []:
    for save in step.get("saves") or []:
        flags[save.get("id")] = save.get("preview")
lines = [l for l in text.splitlines() if l.strip()]
want = [
    root + "/steps/render/saves/image_1.png\tmedia",
    root + "/steps/captions/saves/captions.json\tcaptions",
]
bad = []
if flags.get("contact_sheet") is not True or flags.get("final") is not True:
    bad.append("manifest preview flags changed: %r" % {k: flags.get(k) for k in ("image_1", "contact_sheet", "final")})
if lines != want:
    bad.append("selected=%r want=%r" % (lines, want))
joined = "\n".join(lines)
if "contact_sheet" in joined or "final.png" in joined:
    bad.append("preview leaked into selection")
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi251_sel_check" == "ok" ]]; then
  pass "gfx select: image_1.png + captions, no contact_sheet or final"
else
  fail "gfx select drops preview saves" "$wi251_sel_check"
fi
wi251_only_preview="$(
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_select_deliverables "$wi251" "$(python3 -c '
import json, sys
root = sys.argv[1]
print(json.dumps([
  {"path": root + "/steps/render/saves/contact_sheet.png"},
  {"id": "final", "path": root + "/steps/qa_gate/saves/final.png"},
]))
' "$wi251")"
)"
if [[ -z "$wi251_only_preview" ]]; then
  pass "gfx select: preview-only result selects nothing (no sheet/final fallback)"
else
  fail "gfx select preview-only" "expected empty, got: $wi251_only_preview"
fi
rm -rf "$wi251"

echo "=== Case 40: WI2.45 — one selector, resume with clean work, slide saves, version ==="
# Finding 1: worker must call the tested cr_select_deliverables (no inline copy).
if grep -q 'cr_select_deliverables' "$REPO_DIR/bin/cfw-render.sh" \
  && ! grep -q 'slides_json = os.path.join' "$REPO_DIR/bin/cfw-render.sh"; then
  pass "worker uses shared cr_select_deliverables (no inline slides.json selector)"
else
  fail "worker selector shared" "cfw-render.sh must call cr_select_deliverables and must not inline slides_json selection"
fi

# Finding 2: manifest declares per-slide saves; resume with clean work/ still delivers.
wi245_manifest_ok=1
for n in 1 2 3 4 5 6 7 8 9 10; do
  grep -q "\"id\": \"slide_${n}\"" "$REPO_DIR/skills/p-carousel/manifest.json" || wi245_manifest_ok=0
done
grep -q '"recipeVersion": "2026.10.3"' "$REPO_DIR/skills/p-carousel/manifest.json" || wi245_manifest_ok=0
if [[ "$wi245_manifest_ok" == "1" ]]; then
  pass "carousel manifest: slide_1..slide_10 declared; recipeVersion 2026.10.3"
else
  fail "carousel manifest slide saves" "manifest missing slide_1..slide_10 or recipeVersion 2026.10.3"
fi

wi245="$(mktemp -d)"
mkdir -p "$wi245/steps/render_slides/saves" "$wi245/steps/captions/saves"
# Real sha256 values so the work/ fallback check can reuse this fixture.
python3 - "$wi245" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
saves = os.path.join(root, "steps", "render_slides", "saves")
slides = []
for n, body in enumerate((b"slide-one", b"slide-two", b"slide-three"), 1):
    path = os.path.join(saves, "slide_%d.png" % n)
    open(path, "wb").write(body)
    slides.append({"n": n, "sha256": hashlib.sha256(body).hexdigest(), "bytes": len(body)})
json.dump({"width": 1080, "height": 1350, "count": 3, "slides": slides},
          open(os.path.join(saves, "slides.json"), "w"))
PY
printf 'preview-cover' > "$wi245/steps/render_slides/saves/cover.png"
printf 'preview-sheet' > "$wi245/steps/render_slides/saves/slide_sheet.png"
printf '{"instagram":"Resume caption","default":"Resume caption"}' > "$wi245/steps/captions/saves/captions.json"
# Clean work folder: resume restored saves only; work/ is gone.
rm -rf "$wi245/steps/render_slides/work"
wi245_h_out='[]'
wi245_sel="$(
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_select_deliverables "$wi245" "$wi245_h_out"
)"
wi245_resume_check="$(python3 -c '
import sys
root, text = sys.argv[1], sys.argv[2]
lines = [l for l in text.splitlines() if l.strip()]
want = [
  root + "/steps/render_slides/saves/slide_1.png\tmedia",
  root + "/steps/render_slides/saves/slide_2.png\tmedia",
  root + "/steps/render_slides/saves/slide_3.png\tmedia",
  root + "/steps/captions/saves/captions.json\tcaptions",
]
print("ok" if lines == want else "got=%r want=%r" % (lines, want))
' "$wi245" "$wi245_sel")"
if [[ "$wi245_resume_check" == "ok" ]]; then
  pass "carousel resume: clean work folder still delivers slide_1..slide_N from saves"
else
  fail "carousel resume clean work" "$wi245_resume_check"
fi

# Finding 4: work/slides/slide-N.png fallback only when sha256 matches slides.json.
rm -f "$wi245/steps/render_slides/saves/slide_2.png"
mkdir -p "$wi245/steps/render_slides/work/slides"
printf 'slide-two' > "$wi245/steps/render_slides/work/slides/slide-2.png"
wi245_work_ok="$(
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_select_deliverables "$wi245" "$wi245_h_out"
)"
if [[ "$wi245_work_ok" == *"/work/slides/slide-2.png"$'\tmedia'* ]]; then
  pass "carousel select: work/slides fallback accepted when sha256 matches slides.json"
else
  fail "carousel work fallback match" "expected work slide-2 in selection, got: $wi245_work_ok"
fi
printf 'tampered' > "$wi245/steps/render_slides/work/slides/slide-2.png"
wi245_work_bad="$(
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  cr_select_deliverables "$wi245" "$wi245_h_out"
)"
if [[ -z "$wi245_work_bad" ]]; then
  pass "carousel select: work/slides fallback refused when sha256 mismatches slides.json"
else
  fail "carousel work fallback mismatch" "expected empty, got: $wi245_work_bad"
fi

# Finding 3: sync-skills.py re-applies the p-carousel contract after copy_tree.
# Plant an upstream-shaped p-carousel (no slide_N saves, old step wording) and
# show the synced tree gains slide_1..slide_10, recipeVersion 2026.10.3, and the
# render/captions delivery wording.
wi245_src="$(mktemp -d)"
wi245_sync="$(mktemp -d)"
wi245_recipes="$wi245_src/recipes.json"
mkdir -p "$wi245_src/p-carousel/steps"
printf '%s\n' '{' \
  '  "source": "test-wi245",' \
  '  "recipes": [ { "name": "p-carousel", "version": "1.0.0", "providers": [] } ]' \
  '}' > "$wi245_recipes"
cat > "$wi245_src/p-carousel/SKILL.md" <<'EOF'
---
name: p-carousel
dependsOn: []
---
# p-carousel (WI2.45 sync fixture — upstream shape)

### Step 8 — Deliver ⛔ CHECKPOINT

Deliver: slide PNGs (cover first, in order) + PDF last + `final/captions.json`
**Gate: User approves caption before scheduling.**

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user for feedback.
EOF
python3 - "$wi245_src/p-carousel/manifest.json" <<'PY'
import json, sys
json.dump({
  "manifestFormat": 1,
  "recipe": "p-carousel",
  "recipeVersion": "2026.10.2",
  "label": "Carousel",
  "deliverable": {"kind": "image", "aspect": "4:5", "width": 1080, "height": 1350},
  "needs": {"os": ["macos"], "engines": ["codex"], "tools": ["python3"], "providers": []},
  "inputs": [],
  "steps": [
    {"id": "outline", "label": "Outline", "weight": 15, "runsOn": "computer",
     "when": "always", "instructions": "steps/01-outline.md",
     "saves": [{"id": "outline", "kind": "json", "preview": False}]},
    {"id": "author_slides", "label": "Author", "weight": 25, "runsOn": "computer",
     "when": "always", "instructions": "steps/02-author-slides.md",
     "saves": [{"id": "carousel_html", "kind": "text", "preview": False}]},
    {"id": "render_slides", "label": "Render", "weight": 40, "runsOn": "computer",
     "when": "always", "instructions": "steps/03-render-slides.md",
     "saves": [
       {"id": "cover", "kind": "image", "preview": True},
       {"id": "slide_sheet", "kind": "image", "preview": True},
       {"id": "slides", "kind": "json", "preview": False},
       {"id": "qa_report", "kind": "json", "preview": False}
     ]},
    {"id": "captions", "label": "Captions", "weight": 20, "runsOn": "computer",
     "when": "always", "instructions": "steps/04-captions.md",
     "saves": [{"id": "captions", "kind": "json", "preview": False}]},
  ],
}, open(sys.argv[1], "w"), indent=2)
open(sys.argv[1].replace("manifest.json", "steps/01-outline.md"), "w").write("# outline\n")
open(sys.argv[1].replace("manifest.json", "steps/02-author-slides.md"), "w").write("# author\n")
open(sys.argv[1].replace("manifest.json", "steps/03-render-slides.md"), "w").write(
  "# Render\n\n## You must produce\n\n"
  "- `saves/cover.png` — slide 1.\n"
  "- `saves/slide_sheet.png` — contact sheet.\n"
  "- `saves/slides.json` — metadata.\n"
  "- `saves/qa_report.json` — QA.\n\n"
  "## How\n\n```bash\nmkdir -p work saves\n```\n\n"
  "### 4. Write the saves\n\n```bash\n"
  "cp work/slides/slide-1.png saves/cover.png\n"
  "```\n\n"
  "Keep `work/qa_report.json` up to date.\n\n"
  "## If you cannot proceed\n\nFail.\n"
)
open(sys.argv[1].replace("manifest.json", "steps/04-captions.md"), "w").write(
  "# Write the post captions\n\n"
  "Write captions.\n\n"
  "## You receive\n\n- `prior/slides.json`\n\n"
  "## You must produce\n\n- `saves/captions.json`\n"
)
PY
wi245_sync_rc=0
wi245_sync_log="$(
  CFW_SKILLS_SRC="$wi245_src" "$REPO_DIR/scripts/sync-skills.sh" \
    --recipes "$wi245_recipes" --out-dir "$wi245_sync" --skip-manifest 2>&1
)" || wi245_sync_rc=$?
wi245_sync_check="$(python3 - "$wi245_sync" <<'PY'
import json, os, sys
root = sys.argv[1]
man = json.load(open(os.path.join(root, "p-carousel", "manifest.json")))
bad = []
if man.get("recipeVersion") != "2026.10.3":
    bad.append("recipeVersion=%r" % man.get("recipeVersion"))
step = next(s for s in man["steps"] if s["id"] == "render_slides")
ids = [s["id"] for s in step["saves"]]
want = ["slide_%d" % n for n in range(1, 11)]
if ids[:10] != want:
    bad.append("saves=%r" % ids)
render = open(os.path.join(root, "p-carousel", "steps", "03-render-slides.md")).read()
if "saves/slide_1.png" not in render or "pad any unused" not in render.lower():
    bad.append("03-render-slides missing slide_1/pad wording")
if "MAX_SLIDES = 10" not in render:
    bad.append("03-render-slides missing pad-to-10 save writer")
cap = open(os.path.join(root, "p-carousel", "steps", "04-captions.md")).read()
if "## Delivery boundary" not in cap or "saves/slide_1.png" not in cap:
    bad.append("04-captions missing Delivery boundary")
skill = open(os.path.join(root, "p-carousel", "SKILL.md")).read()
if "cover.png" not in skill or "Never" not in skill:
    bad.append("SKILL.md missing never-cover delivery wording")
idx = json.load(open(os.path.join(root, "index.json")))
if idx["recipes"]["p-carousel"]["version"] != "2026.10.3":
    bad.append("index.version=%r" % idx["recipes"]["p-carousel"]["version"])
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi245_sync_rc" == "0" && "$wi245_sync_check" == "ok" ]]; then
  pass "sync-skills.py re-applies p-carousel slide saves and delivery wording after copy"
else
  fail "sync-skills p-carousel contract" "rc=$wi245_sync_rc check=$wi245_sync_check log=${wi245_sync_log:0:500}"
fi
rm -rf "$wi245_src" "$wi245_sync"

# Finding 2 (review): drive the real harness save-check / restore path with an
# order.json built from the bundled p-carousel manifest — not grep alone.
wi245h="$(mktemp -d)"
mkdir -p "$wi245h/media" "$wi245h/order" "$wi245h/bin"
python3 - "$REPO_DIR" "$wi245h" <<'PY'
import hashlib, json, os, sys
repo, root = sys.argv[1], sys.argv[2]
man = json.load(open(os.path.join(repo, "skills", "p-carousel", "manifest.json")))
assert man["recipeVersion"] == "2026.10.3"
assert [s["id"] for s in next(s for s in man["steps"] if s["id"] == "render_slides")["saves"]][:10] == [
    "slide_%d" % n for n in range(1, 11)
]
media = os.path.join(root, "media")
bodies = {
    "slide_1.png": b"slide-one",
    "slide_2.png": b"slide-two",
    "slide_3.png": b"slide-three",
    "slide_4.png": b"pad-four",
    "slide_5.png": b"pad-five",
    "slide_6.png": b"pad-six",
    "slide_7.png": b"pad-seven",
    "slide_8.png": b"pad-eight",
    "slide_9.png": b"pad-nine",
    "slide_10.png": b"pad-ten",
    "cover.png": b"preview-cover",
    "slide_sheet.png": b"preview-sheet",
    "slides.json": b"",
    "qa_report.json": b'{"rounds":1,"slides":[{"n":1,"verdict":"PASS","notes":[]},{"n":2,"verdict":"PASS","notes":[]},{"n":3,"verdict":"PASS","notes":[]}]}',
    "captions.json": b'{"instagram":"Harness caption","default":"Harness caption"}',
    "outline.json": b'{"count":3}',
    "slide_copy.json": b'{"aspect_ratio":"4:5","slides":[]}',
    "carousel_html.md": b"<html></html>",
}
slides_meta = {
    "width": 1080, "height": 1350, "count": 3,
    "slides": [
        {"n": 1, "sha256": hashlib.sha256(bodies["slide_1.png"]).hexdigest(), "bytes": len(bodies["slide_1.png"])},
        {"n": 2, "sha256": hashlib.sha256(bodies["slide_2.png"]).hexdigest(), "bytes": len(bodies["slide_2.png"])},
        {"n": 3, "sha256": hashlib.sha256(bodies["slide_3.png"]).hexdigest(), "bytes": len(bodies["slide_3.png"])},
    ],
}
bodies["slides.json"] = json.dumps(slides_meta).encode()
for name, body in bodies.items():
    open(os.path.join(media, name), "wb").write(body)
# savedOutputs for every declared save before captions (resume at captions).
saved = []
ext = {"image": "png", "json": "json", "text": "md"}
for step in man["steps"]:
    if step["id"] == "captions":
        break
    for sv in step.get("saves") or []:
        e = ext.get(sv.get("kind"), "bin")
        fname = "%s.%s" % (sv["id"], e)
        path = os.path.join(media, fname)
        if not os.path.isfile(path):
            open(path, "wb").write(b"x")
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        saved.append({
            "stepId": step["id"],
            "saveId": sv["id"],
            "url": "PLACEHOLDER/" + fname,
            "checksum": "sha256:" + digest,
        })
order = {
    "id": "order-wi245h",
    "attempt": {"id": "attempt-wi245h", "number": 1},
    "recipe": "p-carousel",
    "recipeVersion": man["recipeVersion"],
    "kind": "image",
    "brandId": "brand-test",
    "manifest": man,
    "resumeFromStepId": "captions",
    "savedOutputs": saved,
    "taskOrder": {"brand": {"slug": "test-brand"}, "intent": "wi245 harness"},
}
open(os.path.join(root, "order", "order.json"), "w").write(json.dumps(order, indent=2))
open(os.path.join(root, "saved.json"), "w").write(json.dumps(saved))
PY

# Drive harness helpers in a subshell so sourced functions do not leak.
wi245h_port=$((MOCK_PORT_BASE + 1045))
wi245h_result="$(
  set -euo pipefail
  python3 - "$wi245h/media" "$wi245h_port" <<'PY' &
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
class H(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=sys.argv[1], **k)
    def log_message(self, *a):
        pass
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY
  http_pid=$!
  trap 'kill "$http_pid" 2>/dev/null; wait "$http_pid" 2>/dev/null' EXIT
  python3 - "$wi245h" "$wi245h_port" <<'PY'
import json, sys
root, port = sys.argv[1], sys.argv[2]
base = "http://127.0.0.1:%s" % port
path = root + "/order/order.json"
order = json.load(open(path))
for s in order["savedOutputs"]:
    s["url"] = base + "/" + s["url"].split("/", 1)[-1]
json.dump(order, open(path, "w"), indent=2)
PY
  sleep 0.2
  # shellcheck disable=SC1091
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  # shellcheck disable=SC1091
  source "$REPO_DIR/bin/cfw-render-harness.sh"
  # Used by cr_h_saves_for (reads $CR_H_ORDER_DIR/order.json).
  # shellcheck disable=SC2034
  CR_H_ORDER_DIR="$wi245h/order"
  export CFW_RENDER_TEST_MEDIA_BASE_URL="http://127.0.0.1:$wi245h_port"
  export CFW_RENDER_MEDIA_BASE_URL=""

  saves="$(cr_h_saves_for render_slides)"
  saves_ok=1
  for n in 1 2 3 4 5 6 7 8 9 10; do
    [[ " $saves " == *" slide_${n}.png "* ]] || saves_ok=0
  done
  [[ " $saves " == *" cover.png "* ]] || saves_ok=0
  [[ " $saves " == *" slide_sheet.png "* ]] || saves_ok=0
  printf 'SAVES=%s\n' "$saves_ok"
  printf 'SAVES_DETAIL=%s\n' "$saves"

  rm -rf "$wi245h/order/steps"
  mkdir -p "$wi245h/order"
  cr_h_restore_saved_outputs "$wi245h/order/order.json" "$wi245h/order" || true
  restored_check="$(python3 - "$wi245h/order" <<'PY'
import os, sys
root = sys.argv[1]
restored = open(os.path.join(root, "resume-restored.txt")).read().splitlines()
missing = open(os.path.join(root, "resume-missing.txt")).read().strip()
bad = []
if missing:
    bad.append("missing=%r" % missing)
want = ["slide_%d.png" % n for n in range(1, 11)] + ["cover.png", "slide_sheet.png", "slides.json"]
paths = [os.path.basename(p) for p in restored if "/render_slides/saves/" in p.replace("\\", "/")]
for name in want:
    if name not in paths:
        bad.append("not-restored:%s" % name)
    else:
        f = os.path.join(root, "steps", "render_slides", "saves", name)
        if not os.path.isfile(f) or os.path.getsize(f) == 0:
            bad.append("empty:%s" % name)
if os.path.isdir(os.path.join(root, "steps", "render_slides", "work")):
    bad.append("work-folder-present")
print("ok" if not bad else "; ".join(bad))
PY
)"
  printf 'RESTORE=%s\n' "$restored_check"

  check_ok=1
  check_detail=""
  for f in $saves; do
    if [[ ! -s "$wi245h/order/steps/render_slides/saves/$f" ]]; then
      check_ok=0
      check_detail="missing or empty save $f"
      break
    fi
  done
  printf 'CHECK=%s\n' "$check_ok"
  printf 'CHECK_DETAIL=%s\n' "$check_detail"

  mkdir -p "$wi245h/order/steps/captions/saves"
  printf '{"instagram":"Harness caption","default":"Harness caption"}' \
    > "$wi245h/order/steps/captions/saves/captions.json"
  sel="$(cr_select_deliverables "$wi245h/order" '[]')"
  : > "$wi245h/calls.jsonl"
  cat > "$wi245h/bin/cfw-render-upload.sh" <<'EOF'
#!/usr/bin/env bash
printf "https://media.cfw.social/%s\n" "$(basename "$1")"
EOF
  chmod +x "$wi245h/bin/cfw-render-upload.sh"
  cp "$REPO_DIR/bin/cfw-render-lib.sh" "$wi245h/bin/cfw-render-lib.sh"
  cp "$REPO_DIR/bin/cfw-render-report.sh" "$wi245h/bin/cfw-render-report.sh"
  cat >> "$wi245h/bin/cfw-render-lib.sh" <<EOF
cr_mcp_call() {
  printf '%s\n' "\$2" >> "$wi245h/calls.jsonl"
  printf '{"ok":true}'
}
cr_heartbeat_stop_if_pending() { :; }
EOF
  files=()
  captions=""
  while IFS=$'\t' read -r f role; do
    [[ -n "$f" ]] || continue
    if [[ "$role" == "captions" ]]; then captions="$f"; else files+=("$f"); fi
  done <<< "$sel"
  (
    cd "$wi245h/order" || exit 1
    export CFW_ORDER_ID="order-wi245h" CFW_WORKER_ID="w-wi245h" CFW_ATTEMPT_ID="attempt-wi245h"
    export CFW_API_BASE="http://127.0.0.1:9" CFW_RENDER_WORKER_KEY="cfw_render_wi245htestkey000"
    export CFW_RENDER_DIRECTOR_MODEL="sonnet"
    export CFW_CAPTIONS_FILE="${captions}"
    PATH="$wi245h/bin:$PATH"
    bash "$wi245h/bin/cfw-render-report.sh" complete "${files[@]}"
  ) >"$wi245h/complete.out" 2>"$wi245h/complete.err"
  payload="$(python3 -c '
import json, pathlib, sys
calls = pathlib.Path(sys.argv[1])
err = pathlib.Path(sys.argv[2]).read_text(errors="replace")[-400:] if pathlib.Path(sys.argv[2]).is_file() else ""
if not calls.is_file() or not calls.read_text().strip():
    print("parse-error: empty calls; stderr=%r" % err.replace("\n", " | "))
    raise SystemExit(0)
rows = [json.loads(l) for l in calls.read_text().splitlines() if l.strip()]
assert len(rows) == 1, rows
d = rows[0]
names = [u.split("/")[-1] for u in d.get("outputUrls", [])]
bad = []
if names != ["slide_1.png", "slide_2.png", "slide_3.png"]:
  bad.append("names=%r" % names)
if "cover.png" in names or "slide_sheet.png" in names:
  bad.append("preview in outputUrls")
if any(n.startswith("slide_") and n not in ("slide_1.png", "slide_2.png", "slide_3.png") for n in names):
  bad.append("pad-slide leaked: %r" % names)
print("ok" if not bad else "; ".join(bad))
' "$wi245h/calls.jsonl" "$wi245h/complete.err" 2>/dev/null || echo "parse-error")"
  printf 'COMPLETE=%s\n' "$payload"
)"
wi245h_saves_ok="$(printf '%s\n' "$wi245h_result" | sed -n 's/^SAVES=//p' | tail -1)"
wi245h_saves_detail="$(printf '%s\n' "$wi245h_result" | sed -n 's/^SAVES_DETAIL=//p' | tail -1)"
wi245h_restored="$(printf '%s\n' "$wi245h_result" | sed -n 's/^RESTORE=//p' | tail -1)"
wi245h_check_ok="$(printf '%s\n' "$wi245h_result" | sed -n 's/^CHECK=//p' | tail -1)"
wi245h_check_detail="$(printf '%s\n' "$wi245h_result" | sed -n 's/^CHECK_DETAIL=//p' | tail -1)"
wi245h_payload="$(printf '%s\n' "$wi245h_result" | sed -n 's/^COMPLETE=//p' | tail -1)"
if [[ "$wi245h_saves_ok" == "1" ]]; then
  pass "harness cr_h_saves_for: bundled manifest lists slide_1..slide_10 (+ cover/sheet)"
else
  fail "harness cr_h_saves_for slides" "got: $wi245h_saves_detail"
fi
if [[ "$wi245h_restored" == "ok" ]]; then
  pass "harness restore: slide_1..slide_10 checked into saves/ with clean work folder"
else
  fail "harness restore slides" "$wi245h_restored"
fi
if [[ "$wi245h_check_ok" == "1" ]]; then
  pass "harness save-check: every declared render_slides save is present after restore"
else
  fail "harness save-check slides" "$wi245h_check_detail"
fi
if [[ "$wi245h_payload" == "ok" ]]; then
  pass "harness completion: slide_1..slide_N in order, never cover or slide_sheet"
else
  fail "harness completion ordered slides" "$wi245h_payload"
fi
rm -rf "$wi245h"

# Finding 5: skills-version / index version stay aligned with recipeVersion bump.
wi245_ver="$(python3 - "$REPO_DIR" <<'PY'
import json, os, sys
root = sys.argv[1]
idx = json.load(open(os.path.join(root, "skills", "index.json")))
sv = json.load(open(os.path.join(root, "config", "skills-version.json")))
iv = idx["recipes"]["p-carousel"]["version"]
vv = sv["recipes"]["p-carousel"]["version"]
ic = idx["recipes"]["p-carousel"]["checksum"]
vc = sv["recipes"]["p-carousel"]["checksum"]
bad = []
if iv != "2026.10.3": bad.append("index.version=%r" % iv)
if vv != "2026.10.3": bad.append("skills-version.version=%r" % vv)
if ic != vc: bad.append("checksum mismatch index=%s sv=%s" % (ic, vc))
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi245_ver" == "ok" ]]; then
  pass "carousel version: index.json and skills-version.json at 2026.10.3 with matching checksum"
else
  fail "carousel version alignment" "$wi245_ver"
fi
rm -rf "$wi245"

# WI2.32 / WI2.50: the real needs_input path must send count as {min,max}.
# A bare number >= 0 (and a numeric string of one) becomes {min:n,max:n}. An
# object with integer min >= 0 and min <= max passes through. No count stays
# absent. A negative count, a min>max object, and anything else that breaks
# integer / min>=0 / min<=max is dropped and logged once.
wi232="$(mktemp -d)"
wi232_detail="$(
  root="$wi232"
  bad=""
  run_shape() {
    local shape="$1"
    local dir="$root/$shape"
    local rc=0
    local got=""
    mkdir -p "$dir/recipe"
    python3 - "$dir/order.json" <<'PY'
import json, sys
json.dump({
    "id": "ord-wi232",
    "attempt": {"id": "att-wi232"},
    "manifest": {"steps": [{
        "id": "plan_cards",
        "runsOn": "computer",
        "instructions": "steps/missing.md",
        "saves": [{"id": "plan", "kind": "json"}],
    }]},
    "taskOrder": {},
}, open(sys.argv[1], "w"))
PY
    CASE_DIR="$dir"
    ASK_SHAPE="$shape"
    # shellcheck disable=SC1091
    source "$REPO_DIR/bin/cfw-render-harness.sh"
    cr_log() { printf '%s\n' "$*" >> "$CASE_DIR/harness.log"; }
    cr_engine_detect() { echo test; }
    cr_engine_limit_detect() { return 1; }
    cr_harness_heartbeat_start() { :; }
    cr_harness_heartbeat_stop() { :; }
    cr_h_run_with_timeout() { shift; "$@"; }
    cr_engine_run() {
      python3 - "$ASK_SHAPE" "$3/needs_input.json" <<'PY'
import json, sys
shape, path = sys.argv[1], sys.argv[2]
ask = {"inputId": "topic", "reason": "Need a topic."}
if shape == "number":
    ask["count"] = 1
elif shape == "string":
    ask["count"] = "1"
elif shape == "object":
    ask["count"] = {"min": 2, "max": 4}
elif shape == "junk":
    ask["count"] = "soon"
elif shape == "bool":
    ask["count"] = True
elif shape == "negative":
    ask["count"] = -3
elif shape == "inverted":
    ask["count"] = {"min": 4, "max": 1}
json.dump(ask, open(path, "w"))
PY
      return 0
    }
    cr_report_step() {
      python3 -c 'import json,sys; print(json.dumps({"event":sys.argv[1],"extra":json.loads(sys.argv[2])}))' "$5" "$6" >> "$CASE_DIR/events.jsonl"
      printf '%s' '{"ok":true,"directive":"pause"}'
    }
    CFW_WORKER_ID="test-worker" CFW_RENDER_PAUSE_MAX_SEC=0 \
      cr_harness_run "$dir/order.json" "$dir" "$dir/recipe" >"$dir/harness.out" 2>"$dir/harness.err" || rc=$?
    got="$(python3 - "$shape" "$dir/events.jsonl" "$dir/harness.log" <<'PY'
import json, sys
shape, events_path, log_path = sys.argv[1:]
try:
    events = [json.loads(line) for line in open(events_path) if line.strip()]
except Exception as exc:
    print("no events: %s" % exc)
    raise SystemExit(0)
asks = [event["extra"]["ask"] for event in events if event.get("event") == "needs_input"]
try:
    log = open(log_path).read()
except Exception:
    log = ""
drops = log.count("needs_input count dropped")
if len(asks) != 1:
    print("needs_input reports=%s" % len(asks))
    raise SystemExit(0)
ask = asks[0]
problems = []
if ask.get("inputId") != "topic" or ask.get("reason") != "Need a topic.":
    problems.append("ask=%r" % ask)
if shape in ("number", "string"):
    if ask.get("count") != {"min": 1, "max": 1}:
        problems.append("count=%r" % (ask.get("count"),))
    if drops:
        problems.append("unexpected drop")
elif shape == "object":
    if ask.get("count") != {"min": 2, "max": 4}:
        problems.append("count=%r" % (ask.get("count"),))
    if drops:
        problems.append("unexpected drop")
elif shape == "absent":
    if "count" in ask:
        problems.append("count=%r" % (ask.get("count"),))
    if drops:
        problems.append("unexpected drop")
elif shape in ("junk", "bool", "negative", "inverted"):
    if "count" in ask:
        problems.append("count=%r" % (ask.get("count"),))
    if drops != 1:
        problems.append("drops=%s" % drops)
else:
    problems.append("unknown shape")
print("ok" if not problems else "; ".join(problems))
PY
)"
    if [[ "$rc" != "21" || "$got" != "ok" ]]; then
      bad="${bad}${shape}: rc=${rc} ${got}; "
    fi
  }
  run_shape number
  run_shape string
  run_shape object
  run_shape absent
  run_shape junk
  run_shape bool
  run_shape negative
  run_shape inverted
  if [[ -z "$bad" ]]; then printf '%s' ok; else printf '%s' "$bad"; fi
)"
if [[ "$wi232_detail" == "ok" ]]; then
  pass "harness needs_input: numeric count is {min:1,max:1}; object passes through; negative and min>max are dropped"
else
  fail "harness needs_input count shape" "$wi232_detail"
fi
rm -rf "$wi232"

# WI2.49: a typed start answer is written to inputs/<name>/<name>.md before
# the step runs. A URL is still downloaded to the basename, and an existing
# path is still copied. This fails on db62e119, which leaves the typed topic
# unstaged.
wi249="$(mktemp -d)"
wi249_detail="$(
  dir="$wi249"
  mkdir -p "$dir/work" "$dir/src"
  printf 'headshot-bytes' > "$dir/src/headshot.png"
  python3 - "$dir/order.json" "$dir/src/headshot.png" <<'PY'
import json, sys
json.dump({
    "id": "ord-wi249",
    "inputs": {
        "topic": "Three tips for first-time buyers",
        "logo": "https://cdn.example/brand-logo.png?x=1",
        "photo": sys.argv[2],
    },
}, open(sys.argv[1], "w"))
PY
  # shellcheck disable=SC1091
  source "$REPO_DIR/bin/cfw-render-harness.sh"
  curl() {
    local out="" prev="" arg
    for arg in "$@"; do
      if [[ "$prev" == "-o" ]]; then out="$arg"; fi
      prev="$arg"
    done
    printf '%s\n' "$prev" > "$dir/curl.url"
    if [[ -n "$out" ]]; then printf 'downloaded' > "$out"; fi
  }
  cr_h_stage_inputs "$dir/work" "$dir/order.json"
  python3 - "$dir/work" "$dir/src/headshot.png" "$dir/curl.url" <<'PY'
import pathlib, sys
work, photo_src, curl_url_path = sys.argv[1:]
problems = []
topic = pathlib.Path(work) / "inputs" / "topic" / "topic.md"
want = b"Three tips for first-time buyers"
if not topic.is_file():
    problems.append("topic.md missing")
elif topic.read_bytes() != want:
    problems.append("topic.md=%r" % topic.read_bytes())
logo = pathlib.Path(work) / "inputs" / "logo" / "brand-logo.png"
if not logo.is_file() or logo.read_bytes() != b"downloaded":
    problems.append("logo download missing")
if (pathlib.Path(work) / "inputs" / "logo" / "logo.md").exists():
    problems.append("logo written as text")
got_url = pathlib.Path(curl_url_path).read_text(encoding="utf-8").strip() if pathlib.Path(curl_url_path).is_file() else ""
if got_url != "https://cdn.example/brand-logo.png?x=1":
    problems.append("curl url=%r" % got_url)
photo = pathlib.Path(work) / "inputs" / "photo" / "headshot.png"
src = pathlib.Path(photo_src).read_bytes()
if not photo.is_file() or photo.read_bytes() != src:
    problems.append("photo not copied")
if (pathlib.Path(work) / "inputs" / "photo" / "photo.md").exists():
    problems.append("photo written as text")
print("ok" if not problems else "; ".join(problems))
PY
)"
if [[ "$wi249_detail" == "ok" ]]; then
  pass "harness stage inputs: typed topic is inputs/topic/topic.md; URL still downloads"
else
  fail "harness stage inputs typed topic" "$wi249_detail"
fi
rm -rf "$wi249"

# WI2.50: Social refusing report_render_step must end the step failed with the
# refusal text. The directive from step_started stays `continue` on the old
# path, and the needs_input wait then reruns the step. This fails on be009c3f.
wi250="$(mktemp -d)"
wi250_detail="$(
  dir="$wi250"
  mkdir -p "$dir/recipe"
  python3 - "$dir/order.json" <<'PY'
import json, sys
json.dump({
    "id": "ord-wi250",
    "attempt": {"id": "att-wi250"},
    "manifest": {"steps": [{
        "id": "plan_cards",
        "runsOn": "computer",
        "instructions": "steps/missing.md",
        "saves": [{"id": "plan", "kind": "json"}],
    }]},
    "taskOrder": {},
}, open(sys.argv[1], "w"))
PY
  # shellcheck disable=SC1091
  source "$REPO_DIR/bin/cfw-render-harness.sh"
  cr_log() { printf '%s\n' "$*" >> "$dir/harness.log"; }
  cr_engine_detect() { echo test; }
  cr_engine_limit_detect() { return 1; }
  cr_harness_heartbeat_start() { :; }
  cr_harness_heartbeat_stop() { :; }
  cr_h_run_with_timeout() { shift; "$@"; }
  cr_engine_run() {
    local n=0
    if [[ -f "$dir/runs" ]]; then n="$(wc -l < "$dir/runs" | tr -d ' ')"; fi
    printf '%s\n' "$CFW_STEP_ID" >> "$dir/runs"
    if [[ "${n:-0}" == "0" ]]; then
      python3 -c 'import json,sys; json.dump({"inputId":"topic","reason":"Need a topic.","count":1}, open(sys.argv[1],"w"))' "$3/needs_input.json"
      return 0
    fi
    mkdir -p "$3/saves"
    printf '{"ok":true}\n' > "$3/saves/plan.json"
    return 0
  }
  cr_report_step() {
    python3 -c 'import json,sys; print(json.dumps({"event":sys.argv[1],"extra":json.loads(sys.argv[2])}))' "$5" "$6" >> "$dir/events.jsonl"
    if [[ "$5" == "needs_input" ]]; then
      printf '%s' 'Social refused the step report: ask not allowed'
      return 70
    fi
    printf '%s' '{"ok":true,"directive":"continue"}'
  }
  rc=0
  CFW_WORKER_ID="test-worker" CFW_RENDER_PAUSE_MAX_SEC=0 \
    cr_harness_run "$dir/order.json" "$dir" "$dir/recipe" >"$dir/harness.out" 2>"$dir/harness.err" || rc=$?
  python3 - "$rc" "$dir/runs" "$dir/events.jsonl" "$dir/harness.log" <<'PY'
import json, sys
rc, runs_path, events_path, log_path = sys.argv[1:]
problems = []
if rc != "30":
    problems.append("rc=%s" % rc)
try:
    runs = open(runs_path).read().splitlines()
except Exception:
    runs = []
if runs != ["plan_cards"]:
    problems.append("runs=%r" % runs)
try:
    events = [json.loads(line) for line in open(events_path) if line.strip()]
except Exception as exc:
    events = []
    problems.append("events: %s" % exc)
started = [event for event in events if event.get("event") == "step_started"]
if len(started) != 1:
    problems.append("step_started=%s" % len(started))
failed = [event for event in events if event.get("event") == "attempt_failed"]
if len(failed) != 1:
    problems.append("attempt_failed=%s" % len(failed))
else:
    message = failed[0].get("extra", {}).get("message") or ""
    if "Social refused the step report: ask not allowed" not in message:
        problems.append("message=%r" % message)
    if failed[0].get("extra", {}).get("stepId") != "plan_cards":
        problems.append("stepId=%r" % (failed[0].get("extra"),))
log = open(log_path).read() if __import__("os").path.isfile(log_path) else ""
if log.count("tool error:") != 1:
    problems.append("tool-error logs=%s" % log.count("tool error:"))
if "Social refused the step report: ask not allowed" not in log:
    problems.append("refusal missing from log")
print("ok" if not problems else "; ".join(problems))
PY
)"
if [[ "$wi250_detail" == "ok" ]]; then
  pass "harness refused step report: ends failed with the refusal text and does not rerun the step"
else
  fail "harness refused step report" "$wi250_detail"
fi
rm -rf "$wi250"

# WI2.50: number and boolean start answers are staged as text. An input name
# containing / or .. is refused, so the file cannot land outside inputs/.
wi250b="$(mktemp -d)"
wi250b_detail="$(
  dir="$wi250b"
  mkdir -p "$dir/typed/work" "$dir/unsafe/work"
  python3 - "$dir/typed/order.json" <<'PY'
import json, sys
json.dump({
    "id": "ord-wi250-typed",
    "inputs": {"count": 3, "ready": True, "off": False, "zero": 0, "topic": "Hello"},
}, open(sys.argv[1], "w"))
PY
  python3 - "$dir/unsafe/order.json" <<'PY'
import json, sys
json.dump({
    "id": "ord-wi250-unsafe",
    "inputs": {
        "topic": "kept",
        "../outside": "nope",
        "nested/name": "nope",
        "a..b": "nope",
    },
}, open(sys.argv[1], "w"))
PY
  # shellcheck disable=SC1091
  source "$REPO_DIR/bin/cfw-render-harness.sh"
  cr_log() { printf '%s\n' "$*" >> "$dir/harness.log"; }
  typed_rc=0
  cr_h_stage_inputs "$dir/typed/work" "$dir/typed/order.json" || typed_rc=$?
  unsafe_rc=0
  cr_h_stage_inputs "$dir/unsafe/work" "$dir/unsafe/order.json" || unsafe_rc=$?
  python3 - "$typed_rc" "$unsafe_rc" "$dir/typed/work" "$dir/unsafe/work" "$dir/harness.log" <<'PY'
import pathlib, sys
typed_rc, unsafe_rc, typed_work, unsafe_work, log_path = sys.argv[1:]
problems = []
if typed_rc != "0":
    problems.append("typed rc=%s" % typed_rc)
typed = pathlib.Path(typed_work)
expect = {
    "count/count.md": "3",
    "ready/ready.md": "true",
    "off/off.md": "false",
    "zero/zero.md": "0",
    "topic/topic.md": "Hello",
}
for rel, want in expect.items():
    path = typed / "inputs" / rel
    if not path.is_file():
        problems.append("missing %s" % rel)
    elif path.read_text(encoding="utf-8") != want:
        problems.append("%s=%r" % (rel, path.read_text(encoding="utf-8")))
if unsafe_rc != "1":
    problems.append("unsafe rc=%s" % unsafe_rc)
unsafe = pathlib.Path(unsafe_work).resolve()
for path in unsafe.rglob("*"):
    if not path.is_file():
        continue
    rel = path.relative_to(unsafe).as_posix()
    if rel != "brief.json" and not rel.startswith("inputs/"):
        problems.append("escaped %s" % rel)
    if ".." in rel.split("/"):
        problems.append("dotdot %s" % rel)
outside = unsafe / "outside"
nested = unsafe / "inputs" / "nested"
dotty = unsafe / "inputs" / "a..b"
if outside.exists() or nested.exists() or dotty.exists():
    problems.append("unsafe path was created")
log = pathlib.Path(log_path).read_text(encoding="utf-8") if pathlib.Path(log_path).is_file() else ""
lines = [line for line in log.splitlines() if "input name refused" in line]
if len(lines) != 1:
    problems.append("refuse logs=%s" % len(lines))
elif "../outside" not in lines[0] or "nested/name" not in lines[0] or "a..b" not in lines[0]:
    problems.append("refuse log=%r" % lines[0])
print("ok" if not problems else "; ".join(problems))
PY
)"
if [[ "$wi250b_detail" == "ok" ]]; then
  pass "harness stage inputs: number and boolean answers are text; names with / or .. are refused"
else
  fail "harness stage inputs typed scalars and unsafe names" "$wi250b_detail"
fi
rm -rf "$wi250b"

# WI2.54: Social sends inputs as a list of {inputId, items:[{kind,url}]}.
# A video item is staged under inputs/<inputId>/. The old dict form still
# stages. A list inputId with / or .. is refused. An empty list stages nothing.
wi254="$(mktemp -d)"
wi254_detail="$(
  dir="$wi254"
  mkdir -p "$dir/list/work" "$dir/dict/work" "$dir/empty/work" "$dir/unsafe/work"
  python3 - "$dir/list/order.json" "$dir/dict/order.json" "$dir/empty/order.json" "$dir/unsafe/order.json" <<'PY'
import json, sys
list_path, dict_path, empty_path, unsafe_path = sys.argv[1:]
json.dump({
    "id": "ord-wi254-list",
    "inputs": [{
        "inputId": "talking_head",
        "items": [{"kind": "video", "url": "http://127.0.0.1:9/media/talking-head.mp4?sig=1"}],
    }],
}, open(list_path, "w"))
json.dump({
    "id": "ord-wi254-dict",
    "inputs": {
        "topic": "Three tips for first-time buyers",
        "talking_head": [{"kind": "video", "url": "http://127.0.0.1:9/media/dict-head.mp4"}],
    },
}, open(dict_path, "w"))
json.dump({"id": "ord-wi254-empty", "inputs": []}, open(empty_path, "w"))
json.dump({
    "id": "ord-wi254-unsafe",
    "inputs": [
        {"inputId": "../outside", "items": [{"kind": "video", "url": "http://127.0.0.1:9/bad.mp4"}]},
        {"inputId": "nested/name", "items": [{"kind": "video", "url": "http://127.0.0.1:9/bad2.mp4"}]},
    ],
}, open(unsafe_path, "w"))
PY
  # shellcheck disable=SC1091
  source "$REPO_DIR/bin/cfw-render-harness.sh"
  cr_log() { printf '%s\n' "$*" >> "$dir/harness.log"; }
  curl() {
    local out="" prev="" arg
    for arg in "$@"; do
      if [[ "$prev" == "-o" ]]; then out="$arg"; fi
      prev="$arg"
    done
    printf '%s\n' "$prev" >> "$dir/curl.urls"
    if [[ -n "$out" ]]; then printf 'video-bytes\n' > "$out"; fi
  }
  list_rc=0
  cr_h_stage_inputs "$dir/list/work" "$dir/list/order.json" || list_rc=$?
  dict_rc=0
  cr_h_stage_inputs "$dir/dict/work" "$dir/dict/order.json" || dict_rc=$?
  empty_rc=0
  cr_h_stage_inputs "$dir/empty/work" "$dir/empty/order.json" || empty_rc=$?
  unsafe_rc=0
  cr_h_stage_inputs "$dir/unsafe/work" "$dir/unsafe/order.json" || unsafe_rc=$?
  python3 - "$dir" "$list_rc" "$dict_rc" "$empty_rc" "$unsafe_rc" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
list_rc, dict_rc, empty_rc, unsafe_rc = sys.argv[2:]
problems = []
if list_rc != "0":
    problems.append("list rc=%s" % list_rc)
video = root / "list/work/inputs/talking_head/talking-head.mp4"
if not video.is_file() or video.read_text(encoding="utf-8") != "video-bytes\n":
    problems.append("list video missing")
if (root / "list/work/inputs/talking_head/talking_head.md").exists():
    problems.append("list video written as text")
if dict_rc != "0":
    problems.append("dict rc=%s" % dict_rc)
topic = root / "dict/work/inputs/topic/topic.md"
if not topic.is_file() or topic.read_text(encoding="utf-8") != "Three tips for first-time buyers":
    problems.append("dict topic=%r" % (topic.read_text(encoding="utf-8") if topic.is_file() else None))
dict_video = root / "dict/work/inputs/talking_head/dict-head.mp4"
if not dict_video.is_file() or dict_video.read_text(encoding="utf-8") != "video-bytes\n":
    problems.append("dict video missing")
if empty_rc != "0":
    problems.append("empty rc=%s" % empty_rc)
empty_inputs = root / "empty/work/inputs"
if empty_inputs.exists() and any(empty_inputs.rglob("*")):
    problems.append("empty list staged files")
if unsafe_rc != "1":
    problems.append("unsafe rc=%s" % unsafe_rc)
unsafe = (root / "unsafe/work").resolve()
for path in unsafe.rglob("*"):
    if not path.is_file():
        continue
    rel = path.relative_to(unsafe).as_posix()
    if rel != "brief.json" and not rel.startswith("inputs/"):
        problems.append("escaped %s" % rel)
outside = root / "unsafe/outside"
nested = root / "unsafe/work/inputs/nested"
if outside.exists() or nested.exists() or (root / "outside").exists():
    problems.append("unsafe path was created")
urls = (root / "curl.urls").read_text(encoding="utf-8") if (root / "curl.urls").is_file() else ""
if "http://127.0.0.1:9/media/talking-head.mp4?sig=1" not in urls:
    problems.append("list url not downloaded")
if "http://127.0.0.1:9/media/dict-head.mp4" not in urls:
    problems.append("dict url not downloaded")
if "bad.mp4" in urls or "bad2.mp4" in urls:
    problems.append("refused url was downloaded")
print("ok" if not problems else "; ".join(problems))
PY
)"
if [[ "$wi254_detail" == "ok" ]]; then
  pass "harness stage inputs: list-form video is inputs/talking_head/; dict form still stages"
else
  fail "harness stage inputs list form" "$wi254_detail"
fi
rm -rf "$wi254"

# WI2.54: a harness exit of 1 must report attempt_failed with a reason.
# Exit 30 already reported inside the harness, so the worker must not send
# another attempt_failed. An older harness line in the shared log is not
# this run's reason.
wi254w="$(mktemp -d)"
wi254w_detail="$(
  python3 - "$REPO_DIR" "$wi254w" <<'PY'
import json, os, pathlib, subprocess, sys
repo = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
source = (repo / "bin/cfw-render.sh").read_text()
functions = source[source.index("sanitize_slug() {"):source.index("\nspawn_pids=()")]
(root / "state").mkdir()
(root / "logs").mkdir()
(root / "scratch").mkdir()
env = {
    "PATH": os.environ["PATH"],
    "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "HOME": str(root),
    "TEST_ROOT": str(root),
    "SELF_DIR": str(repo / "bin"),
    "CFW_RENDER_SCRATCH": str(root / "scratch"),
    "CFW_RENDER_STATE_DIR": str(root / "state"),
    "CFW_RENDER_LOG_DIR": str(root / "logs"),
    "CFW_RENDER_SKILLS_DIR": str(root / "skills"),
    "CFW_WORKER_ID": "worker-wi254",
    "CFW_API_BASE": "http://127.0.0.1:9",
    "CFW_RENDER_WORKER_KEY": "synthetic-key",
    "CFW_RENDER_COMPUTER_NAME": "Synthetic Mac",
    "CFW_RENDER_KEEP_OUTPUTS": "0",
}
setup = r'''
set -u
source "$SELF_DIR/cfw-render-lib.sh"
JOURNAL="$CFW_RENDER_STATE_DIR/journal.tsv"
RUNS_DIR="$CFW_RENDER_LOG_DIR/runs"
mkdir -p "$RUNS_DIR"
cr_recipe_needs_heygen() { return 1; }
cr_verify_skills_bundle() { return 0; }
cr_mcp_call() { return 0; }
cr_event() { :; }
cr_keep_output_dir() { echo "$TEST_ROOT/kept/$2"; }
cr_harness_run() {
  if [[ "$TEST_LOG_STAGING" == "1" ]]; then
    cr_log "harness: input staging failed"
  fi
  return "$TEST_HARNESS_RC"
}
cr_report_step() {
  python3 -c 'import json,sys; print(json.dumps({"orderId":sys.argv[1],"workerId":sys.argv[2],"attemptId":sys.argv[3],"seq":int(sys.argv[4]),"event":sys.argv[5],"extra":json.loads(sys.argv[6])}))' "$@" >> "$TEST_ROOT/reports.jsonl"
  printf '%s' '{"ok":true,"directive":"continue"}'
}
'''
script = setup + functions + '\nspawn_director "$TEST_CLAIM"\nexit $?\n'

def claim(order_id):
    return {
        "id": order_id,
        "brandId": "b1",
        "brandName": "Brand A",
        "taskOrder": {"brand": {"slug": "brand-a"}},
        "recipe": "p-reels-pip",
        "kind": "video",
        "attempt": {"id": "att-" + order_id},
        "manifest": {"steps": [{"id": "prepare_footage", "runsOn": "computer"}]},
    }

def run(order_id, harness_rc, log_staging):
    reports = root / "reports.jsonl"
    if reports.exists():
        reports.unlink()
    proc = subprocess.run(
        ["bash", "--noprofile", "--norc", "-c", script],
        env={**env, "TEST_CLAIM": json.dumps(claim(order_id)),
             "TEST_HARNESS_RC": harness_rc, "TEST_LOG_STAGING": log_staging},
        text=True, capture_output=True, timeout=30)
    rows = []
    if reports.is_file():
        rows = [json.loads(line) for line in reports.read_text().splitlines() if line.strip()]
    return proc, rows

problems = []
staged, staged_rows = run("order-wi254", "1", "1")
if staged.returncode != 0:
    problems.append("stage rc=%s %s" % (staged.returncode, staged.stderr[-400:]))
if len(staged_rows) != 1:
    problems.append("stage reports=%s" % staged_rows)
else:
    row = staged_rows[0]
    if row.get("event") != "attempt_failed":
        problems.append("event=%s" % row.get("event"))
    if row.get("orderId") != "order-wi254" or row.get("attemptId") != "att-order-wi254":
        problems.append("identity=%s" % row)
    if row.get("workerId") != "worker-wi254" or row.get("seq") != 1:
        problems.append("seq=%s worker=%s" % (row.get("seq"), row.get("workerId")))
    if (row.get("extra") or {}).get("message") != "harness-failed: input staging failed":
        problems.append("message=%r" % ((row.get("extra") or {}).get("message")))
order_dir = root / "scratch/brand-a/order-wi254"
if not order_dir.is_dir():
    problems.append("order dir removed")
journal = (root / "state/journal.tsv").read_text(encoding="utf-8") if (root / "state/journal.tsv").is_file() else ""
if "order-wi254" not in journal or "harness-failed" not in journal:
    problems.append("journal=%r" % journal)
stale, stale_rows = run("order-wi254b", "1", "0")
if stale.returncode != 0:
    problems.append("stale rc=%s %s" % (stale.returncode, stale.stderr[-400:]))
if len(stale_rows) != 1 or (stale_rows[0].get("extra") or {}).get("message") != "harness-failed":
    problems.append("stale message=%s" % stale_rows)
elif "input staging failed" in (stale_rows[0].get("extra") or {}).get("message", ""):
    problems.append("stale reused an older harness line")
other, other_rows = run("order-wi254c", "30", "1")
if other.returncode != 0:
    problems.append("rc30=%s %s" % (other.returncode, other.stderr[-400:]))
if other_rows:
    problems.append("rc30 reported %s" % other_rows)
print("ok" if not problems else "; ".join(problems))
PY
)"
if [[ "$wi254w_detail" == "ok" ]]; then
  pass "worker: harness exit 1 reports attempt_failed with the harness reason"
else
  fail "worker harness exit 1 attempt_failed" "$wi254w_detail"
fi
rm -rf "$wi254w"

echo "=== Case 41: WI2.61 — quiet reel audio is sealed to -14 LUFS before the gate ==="
wi261_detail="$(python3 - "$REPO_DIR" <<'PY'
import re, subprocess, sys, tempfile
from pathlib import Path

repo = Path(sys.argv[1])
checks = (repo / "bin" / "cfw-render-checks.py").read_text()
harness = (repo / "bin" / "cfw-render-harness.sh").read_text()
problems = []
if "-15.5 <= float(values[-1]) <= -12.5" not in checks or "Loudness must be minus 14 LUFS, within 1.5 LUFS." not in checks:
    problems.append("gate target changed")
if 'normalize_loudness(self.artifact(), self.recipe)' not in checks:
    problems.append("evidence does not seal before hashing")
evidence_body = checks.split("def make_evidence", 1)[1].split("def review", 1)[0]
if "normalize_loudness" not in evidence_body or evidence_body.find("normalize_loudness") > evidence_body.find("qa/review.json"):
    problems.append("seal is after evidence is written")
if 'normalize_loudness(local(work, "saves/final_video.mp4"), recipe)' not in checks or "sealed_evidence" not in checks:
    problems.append("spotlight run can rewrite hashed evidence")
if 'FINAL_LOUDNESS_RECIPES = ("p-reels-spotlight", "p-reels-pip")' not in checks:
    problems.append("pip is not sealed with spotlight")
if "loudnorm=I=-14:TP=-1.5:LRA=11" not in checks or ":linear=true" not in checks or '"-c:v", "copy"' not in checks:
    problems.append("two-pass copy seal is missing")
if 'cr_h_seal_final_loudness "$step_id" "$workdir"' not in harness or "p-reels-spotlight|p-reels-pip" not in harness:
    problems.append("harness does not seal both recipes before its checks")
seal_fn = harness.split("cr_h_seal_final_loudness()", 1)[1].split("\ncr_h_run_checks()", 1)[0]
loudnorm_at = seal_fn.find("loudnorm")
if loudnorm_at < 0 or "|| return 0" in seal_fn[loudnorm_at:loudnorm_at + 500] or "final loudness normalisation failed" not in seal_fn:
    problems.append("a real loudnorm failure is swallowed")

def last_lufs(path):
    probe = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(path), "-af", "ebur128", "-f", "null", "-"],
        capture_output=True, text=True)
    values = re.findall(r"I:\s*(-?[0-9.]+) LUFS", probe.stderr)
    if probe.returncode != 0 or not values:
        return None
    return float(values[-1])

def one_frame(path):
    frame = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True)
    return frame.returncode, frame.stdout

with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / "quiet.mp4"
    gen = subprocess.run([
        "ffmpeg", "-y",
        "-f", "lavfi", "-i", "color=c=red:s=320x240:r=30:d=8",
        "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=8",
        "-filter:a", "volume=-21dB",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
        "-shortest", str(src),
    ], capture_output=True, text=True)
    if gen.returncode != 0 or not src.is_file():
        problems.append("could not generate a quiet sine")
    else:
        before_rc, before = one_frame(src)
        quiet = last_lufs(src)
        if before_rc != 0 or not before:
            problems.append("could not read the input frame")
        if quiet is None or quiet > -20:
            problems.append("input measured %s LUFS, want about -24" % quiet)
        seal = subprocess.run(
            [sys.executable, str(repo / "bin" / "cfw-render-checks.py"), "loudnorm", str(src)],
            capture_output=True, text=True)
        if seal.returncode != 0:
            problems.append("loudnorm failed: %s" % ((seal.stdout or seal.stderr)[-300:]))
        else:
            after_rc, after = one_frame(src)
            if after_rc != 0 or after != before:
                problems.append("video frame changed; stream copy did not hold")
            measured = last_lufs(src)
            if measured is None or not (-15.5 <= measured <= -12.5):
                problems.append("sealed loudness %s is outside -14 +/- 1.5" % measured)
            if list(Path(tmp).glob("*.cfw-loudnorm.mp4")):
                problems.append("loudnorm left a temporary file")

print("ok" if not problems else "; ".join(problems))
raise SystemExit(0 if not problems else 1)
PY
)"
wi261_rc=$?
if [[ "$wi261_rc" == "0" && "$wi261_detail" == "ok" ]]; then
  pass "WI2.61: quiet sine seals inside -14 LUFS +/- 1.5 and the gate target is unchanged"
else
  fail "WI2.61 final loudness seal" "$wi261_detail"
fi

echo "=== Case 42: WI2.61 — spotlight run sees sealed evidence and does not re-encode ==="
# Python falls back to /tmp when TMPDIR is missing. The sandbox refuses that.
# Put this case back on the directory the suite started with.
if [[ -n "${SUITE_TMPDIR}" && -d "${SUITE_TMPDIR}" && -w "${SUITE_TMPDIR}" ]]; then
  export TMPDIR="${SUITE_TMPDIR}" TMP="${SUITE_TMPDIR}" TEMP="${SUITE_TMPDIR}"
fi
wi261b_detail="$(python3 - "$REPO_DIR" <<'PY'
import hashlib, importlib.util, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

repo = Path(sys.argv[1])
checks_py = repo / "bin" / "cfw-render-checks.py"
recipe_dir = repo / "skills" / "p-reels-spotlight"
problems = []

spec = importlib.util.spec_from_file_location("cfw_render_checks_wi261", checks_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
if mod.recipe_loudness_target(recipe_dir) != (-14.0, -1.5, 11.0):
    problems.append("spotlight default target %s" % (mod.recipe_loudness_target(recipe_dir),))
pip_target = mod.recipe_loudness_target(repo / "skills" / "p-reels-pip")
if pip_target[0] != -14.0 or pip_target[1] != -1.5:
    problems.append("pip target %s" % (pip_target,))

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def last_lufs(path):
    probe = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(path), "-af", "ebur128", "-f", "null", "-"],
        capture_output=True, text=True)
    import re
    values = re.findall(r"I:\s*(-?[0-9.]+) LUFS", probe.stderr)
    if probe.returncode != 0 or not values:
        return None
    return float(values[-1])

suite_tmp = os.environ.get("TMPDIR") or ""
if not os.path.isdir(suite_tmp) or not os.access(suite_tmp, os.W_OK):
    problems.append("suite TMPDIR is not writable")
    print("; ".join(problems))
    raise SystemExit(1)
os.environ["TMPDIR"] = os.environ["TEMP"] = os.environ["TMP"] = suite_tmp
tempfile.tempdir = suite_tmp
with tempfile.TemporaryDirectory(dir=suite_tmp) as tmp:
    root = Path(tmp)
    custom = root / "custom-recipe"
    custom.mkdir()
    (custom / "acceptance.json").write_text(json.dumps({
        "checks": [
            {"id": "qa_gate", "type": "qa_gate", "target": -14, "tp": -1.5, "lra": 11},
        ],
        "steps": {"voicebed": {"checks": [
            {"id": "bed_loudness", "type": "loudness", "target": -23, "tol": 1.5},
        ]}},
    }))
    if mod.recipe_loudness_target(custom) != (-14.0, -1.5, 11.0):
        problems.append("qa_gate target lost %s" % (mod.recipe_loudness_target(custom),))
    (custom / "acceptance.json").write_text(json.dumps({
        "checks": [{"id": "qa_gate", "type": "qa_gate", "target": -18, "tp": -2, "lra": 7}],
    }))
    if mod.recipe_loudness_target(custom) != (-18.0, -2.0, 7.0):
        problems.append("declared target %s" % (mod.recipe_loudness_target(custom),))

    src = root / "quiet.mp4"
    gen = subprocess.run([
        "ffmpeg", "-y",
        "-f", "lavfi", "-i", "color=c=red:s=1080x1920:r=30:d=8",
        "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=8",
        "-filter:a", "volume=-21dB",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30",
        "-c:a", "aac", "-b:a", "192k", "-shortest", str(src),
    ], capture_output=True, text=True)
    if gen.returncode != 0 or not src.is_file():
        problems.append("could not generate a quiet reel")
    else:
        work = root / "work"
        (work / "saves").mkdir(parents=True)
        (work / "prior").mkdir()
        (work / "inputs" / "broll").mkdir(parents=True)
        shutil.copy(src, work / "saves" / "final_video.mp4")
        shutil.copy(src, work / "prior" / "assembled_video.mp4")
        cover = subprocess.run([
            "ffmpeg", "-y", "-i", str(src), "-frames:v", "1", str(work / "saves" / "cover.png"),
        ], capture_output=True, text=True)
        if cover.returncode != 0:
            problems.append("could not write cover.png")
        (work / "prior" / "edit_plan.json").write_text(json.dumps({"takeovers": [], "cover_at": 1.0}))
        order = root / "order.json"
        order.write_text(json.dumps({
            "manifest": {
                "recipe": "p-reels-spotlight",
                "steps": [{
                    "id": "final_checks",
                    "saves": [{"id": "final_video", "kind": "video"}],
                    "checks": [{"id": "qa_gate"}, {"id": "grade_is_subtle"}],
                }],
            },
        }))
        evidence = subprocess.run(
            [sys.executable, str(checks_py), "evidence", str(recipe_dir), str(work), "final_checks"],
            capture_output=True, text=True, timeout=180)
        if evidence.returncode != 0:
            problems.append("evidence failed: %s" % ((evidence.stdout or evidence.stderr)[-400:]))
        else:
            review = json.loads((work / "qa" / "review.json").read_text())
            for row in review["checks"]:
                row["status"] = "PASS"
                row["reviewer"] = "wi261-test"
                row["observations"] = "Red frame reviewed after the loudness seal."
            (work / "qa" / "review.json").write_text(json.dumps(review, indent=2) + "\n")
            video = work / "saves" / "final_video.mp4"
            sealed = sha(video)
            measured = last_lufs(video)
            if measured is None or not (-15.5 <= measured <= -12.5):
                problems.append("evidence seal loudness %s" % measured)
            again = subprocess.run(
                [sys.executable, str(checks_py), "loudnorm", str(video), str(recipe_dir)],
                capture_output=True, text=True, timeout=120)
            if again.returncode != 0:
                problems.append("retry loudnorm failed: %s" % ((again.stdout or again.stderr)[-300:]))
            elif sha(video) != sealed:
                problems.append("retry re-encoded final_video")

            def run_mode():
                proc = subprocess.run(
                    [sys.executable, str(checks_py), "run", str(order), str(recipe_dir), str(work), "final_checks"],
                    capture_output=True, text=True, timeout=180)
                try:
                    rows = json.loads(proc.stdout)
                except json.JSONDecodeError:
                    rows = None
                return proc, rows

            first, rows = run_mode()
            if rows is None:
                problems.append("run output not json: %s" % ((first.stdout or first.stderr)[-400:]))
            else:
                stale = [r for r in rows if "stale" in str(r.get("detail") or "").lower()]
                if stale:
                    problems.append("stale checks: %s" % stale)
                by_id = {r["id"]: r for r in rows}
                for cid in ("qa_gate", "grade_is_subtle"):
                    if not by_id.get(cid, {}).get("passed"):
                        problems.append("%s failed: %s" % (cid, by_id.get(cid)))
                if sha(video) != sealed:
                    problems.append("run re-encoded final_video")
                second, rows2 = run_mode()
                if rows2 is None:
                    problems.append("retry run output not json: %s" % ((second.stdout or second.stderr)[-300:]))
                else:
                    stale2 = [r for r in rows2 if "stale" in str(r.get("detail") or "").lower()]
                    if stale2:
                        problems.append("retry stale: %s" % stale2)
                    if sha(video) != sealed:
                        problems.append("retry run re-encoded final_video")
                if last_lufs(video) is None or not (-15.5 <= last_lufs(video) <= -12.5):
                    problems.append("run loudness %s" % last_lufs(video))
            if list(work.rglob("*.cfw-loudnorm.mp4")) or list(work.rglob("*.cfw-loudnorm-prev.mp4")):
                problems.append("loudnorm left a temporary file")

    # Non-local harness: a real media failure is a failed check plus a log line.
    # A placeholder save is skipped. Local mode does not seal here.
    wrap = root / "wrap"
    wrap.mkdir()
    real = sys.executable
    (wrap / "python3").write_text(
        "#!/bin/sh\nfor a in \"$@\"; do\n"
        "  if [ \"$a\" = \"loudnorm\" ]; then echo \"loudnorm encoder failed\"; exit 1; fi\ndone\n"
        "exec \"%s\" \"$@\"\n" % real)
    os.chmod(wrap / "python3", 0o755)
    order_dir = root / "order-dir"
    order_dir.mkdir()
    (order_dir / "order.json").write_text(json.dumps({"manifest": {"recipe": "p-reels-spotlight"}}))
    fail_wd = root / "fail-wd"
    (fail_wd / "saves").mkdir(parents=True)
    shutil.copy(src, fail_wd / "saves" / "final_video.mp4")
    ph_wd = root / "ph-wd"
    (ph_wd / "saves").mkdir(parents=True)
    (ph_wd / "saves" / "final_video.mp4").write_text("placeholder\n")
    log = root / "harness.log"
    script = r'''
source "$REPO/bin/cfw-render-harness.sh"
cr_log() { printf '%s\n' "$*" >> "$LOG"; }
export PATH="$WRAP:$PATH"
CR_H_ORDER_DIR="$ORDER_DIR"
CR_H_RECIPE_DIR="$RECIPE"
CR_H_LOCAL=0
: > "$LOG"
seal_rc=0
cr_h_seal_final_loudness final_checks "$FAIL_WD" || seal_rc=$?
seal_log="$(cat "$LOG")"
: > "$LOG"
place_rc=0
cr_h_seal_final_loudness final_checks "$PH_WD" || place_rc=$?
place_log="$(cat "$LOG")"
CR_H_LOCAL=1
local_rc=0
cr_h_seal_final_loudness final_checks "$FAIL_WD" || local_rc=$?
CR_H_LOCAL=0
: > "$LOG"
check_rc=0
check_out="$(cr_h_run_checks final_checks "$FAIL_WD" qa_gate)" || check_rc=$?
check_log="$(cat "$LOG")"
printf 'SEAL=%s\nPLACE=%s\nLOCAL=%s\nCHECK=%s\n' "$seal_rc" "$place_rc" "$local_rc" "$check_rc"
printf 'SEAL_LOG=%s\n' "$seal_log"
printf 'PLACE_LOG=%s\n' "$place_log"
printf 'CHECK_OUT=%s\n' "$check_out"
printf 'CHECK_LOG=%s\n' "$check_log"
'''
    env = os.environ.copy()
    env.update({
        "REPO": str(repo),
        "WRAP": str(wrap),
        "ORDER_DIR": str(order_dir),
        "RECIPE": str(recipe_dir),
        "FAIL_WD": str(fail_wd),
        "PH_WD": str(ph_wd),
        "LOG": str(log),
        "PATH": str(wrap) + os.pathsep + env.get("PATH", ""),
    })
    harness = subprocess.run(["bash", "--noprofile", "--norc", "-c", script], capture_output=True, text=True, env=env, timeout=60)
    text = harness.stdout + "\n" + harness.stderr
    if harness.returncode != 0 and "SEAL=" not in harness.stdout:
        problems.append("harness probe failed: %s" % text[-500:])
    else:
        fields = {}
        for line in harness.stdout.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                fields[key] = value
        if fields.get("SEAL") != "1" or "final loudness normalisation failed" not in fields.get("SEAL_LOG", ""):
            problems.append("real seal failure hidden: %s" % fields)
        if "loudnorm encoder failed" not in fields.get("SEAL_LOG", ""):
            problems.append("seal log dropped the tool error: %s" % fields.get("SEAL_LOG"))
        if fields.get("PLACE") != "0" or "normalisation failed" in fields.get("PLACE_LOG", ""):
            problems.append("placeholder was not skipped: %s" % fields)
        if fields.get("LOCAL") != "0":
            problems.append("local harness sealed: %s" % fields.get("LOCAL"))
        if fields.get("CHECK") != "1" or "Final loudness normalisation failed." not in fields.get("CHECK_OUT", ""):
            problems.append("run_checks hid the seal failure: %s" % fields)

print("ok" if not problems else "; ".join(problems))
raise SystemExit(0 if not problems else 1)
PY
)"
wi261b_rc=$?
if [[ "$wi261b_rc" == "0" && "$wi261b_detail" == "ok" ]]; then
  pass "WI2.61: spotlight run keeps fresh review evidence and a retry does not re-encode"
else
  fail "WI2.61 spotlight run after loudness seal" "$wi261b_detail"
fi

echo "=== Case 43: WI2.62 — harness seals the quiet prior before the final_checks step order ==="
# Python falls back to /tmp when TMPDIR is missing. The sandbox refuses that.
if [[ -n "${SUITE_TMPDIR}" && -d "${SUITE_TMPDIR}" && -w "${SUITE_TMPDIR}" ]]; then
  export TMPDIR="${SUITE_TMPDIR}" TMP="${SUITE_TMPDIR}" TEMP="${SUITE_TMPDIR}"
fi
wi262_detail="$(python3 - "$REPO_DIR" <<'PY'
import json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

repo = Path(sys.argv[1])
checks_py = repo / "bin" / "cfw-render-checks.py"
harness = (repo / "bin" / "cfw-render-harness.sh").read_text()
checks_src = checks_py.read_text()
problems = []

# Gate target unchanged; WI2.61 guarantees kept.
if "-15.5 <= float(values[-1]) <= -12.5" not in checks_src:
    problems.append("gate target changed")
if 'normalize_loudness(self.artifact(), self.recipe)' not in checks_src:
    problems.append("evidence seal missing")
if "final loudness normalisation failed" not in harness:
    problems.append("harness no longer reports a real loudnorm failure")

# The prior seal runs in the step loop, before the prompt and the agent.
# The evidence block stays on the local spotlight call. Step docs stay pinned.
call = harness.find('cr_h_seal_prior_loudness "$step_id" "$workdir"')
built = harness.find('cr_h_build_prompt "$step_id" "$workdir" "$order_file"', call if call >= 0 else 0)
engine = harness.find('cr_engine_run "$engine"', built if built >= 0 else 0)
if call < 0 or built < 0 or engine < 0 or not (call < built < engine):
    problems.append("prior seal is not before the final_checks agent")
prior_fn = harness.split("cr_h_seal_prior_loudness()", 1)[1].split("\ncr_h_seal_final_loudness()", 1)[0]
if "prior/assembled_video.mp4" not in prior_fn or "p-reels-spotlight|p-reels-pip" not in prior_fn:
    problems.append("prior seal does not cover both reel recipes' OUT_RAW")
if "CR_H_LOCAL" in prior_fn:
    problems.append("prior seal skips local or non-local")
invoke = prior_fn.find('cfw-render-checks.py" loudnorm')
window = prior_fn[invoke:invoke + 500] if invoke >= 0 else ""
if invoke < 0 or "|| return 0" in window or "final loudness normalisation failed" not in window:
    problems.append("a real prior loudnorm failure is swallowed")
instr = checks_src.split("def instructions", 1)[1].split("\ndef run", 1)[0]
evidence_at = instr.find("Required local QA evidence")
local_gate = instr.find('recipe.name != "p-reels-spotlight" or not local')
if evidence_at < 0 or local_gate < 0 or local_gate > evidence_at:
    problems.append("Required local QA evidence is not limited to local spotlight prompts")
if "loudnorm saves/final_video.mp4" in instr:
    problems.append("instructions still tell the agent to loudnorm final_video")
prompt_fn = harness.split("cr_h_build_prompt()", 1)[1].split("\ncr_h_write_brief()", 1)[0]
instr_call = prompt_fn.find('instructions "$CR_H_RECIPE_DIR"')
local_if = prompt_fn.rfind("CR_H_LOCAL", 0, instr_call if instr_call >= 0 else 0)
if instr_call < 0 or local_if < 0 or "local >>" not in prompt_fn[instr_call:instr_call + 80]:
    problems.append("evidence instructions are not passed only for CR_H_LOCAL")

def last_lufs(path):
    probe = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(path), "-af", "ebur128", "-f", "null", "-"],
        capture_output=True, text=True)
    values = re.findall(r"I:\s*(-?[0-9.]+) LUFS", probe.stderr)
    if probe.returncode != 0 or not values:
        return None
    return float(values[-1])

suite_tmp = os.environ.get("TMPDIR") or ""
if not os.path.isdir(suite_tmp) or not os.access(suite_tmp, os.W_OK):
    problems.append("suite TMPDIR is not writable")
    print("; ".join(problems))
    raise SystemExit(1)
os.environ["TMPDIR"] = os.environ["TEMP"] = os.environ["TMP"] = suite_tmp
tempfile.tempdir = suite_tmp

with tempfile.TemporaryDirectory(dir=suite_tmp) as tmp:
    root = Path(tmp)
    # Quiet reel near -16 LUFS (bed convention; outside the -14 +/- 1.5 gate).
    src = root / "quiet-16.mp4"
    gen = subprocess.run([
        "ffmpeg", "-y",
        "-f", "lavfi", "-i", "color=c=red:s=1080x1920:r=30:d=8",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=8",
        "-af", "loudnorm=I=-16.5:TP=-1.5:LRA=11",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30",
        "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
        "-shortest", str(src),
    ], capture_output=True, text=True)
    if gen.returncode != 0 or not src.is_file():
        problems.append("could not generate quiet -16 reel: %s" % (gen.stderr or gen.stdout)[-300:])
        print("; ".join(problems))
        raise SystemExit(1)
    quiet = last_lufs(src)
    # Must sit near -16 and outside the gate window (-14 +/- 1.5 => [-15.5, -12.5]).
    if quiet is None or quiet > -15.5 or quiet < -18.0:
        problems.append("input measured %s LUFS, want about -16 and outside the gate" % quiet)

    def bash_fences(prompt):
        return re.findall(r"```bash\n(.*?)```", prompt, re.S)

    def one_block(prompt, pred, label):
        hits = [b for b in bash_fences(prompt) if pred(b)]
        if len(hits) != 1:
            problems.append("%s: expected one step block, found %d" % (label, len(hits)))
            return None
        return hits[0]

    def run_bash(script, env, timeout):
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-c", script],
            capture_output=True, text=True, env=env, timeout=timeout)

    skills = str(repo / "skills")
    for slug in ("p-reels-pip", "p-reels-spotlight"):
        recipe_dir = repo / "skills" / slug
        manifest = json.loads((recipe_dir / "manifest.json").read_text())
        if manifest.get("recipe") != slug:
            problems.append("%s manifest recipe mismatch" % slug)
            continue
        for local_flag in ("0", "1"):
            label = "%s local=%s" % (slug, local_flag)
            wd = root / ("%s-%s" % (slug, local_flag))
            (wd / "prior").mkdir(parents=True)
            (wd / "inputs").mkdir()
            shutil.copy(src, wd / "prior" / "assembled_video.mp4")
            if slug == "p-reels-pip":
                (wd / "prior" / "beat_list.json").write_text(json.dumps({"cover_at": 1.0, "beats": []}))
            else:
                (wd / "prior" / "edit_plan.json").write_text(json.dumps({"cover_at": 1.0, "takeovers": []}))
            (wd / "brief.json").write_text(json.dumps({
                "recipe": slug,
                "brand": {"slug": "test-brand"},
                "targets": ["instagram"],
            }))
            order_dir = root / ("order-%s-%s" % (slug, local_flag))
            order_dir.mkdir()
            order = order_dir / "order.json"
            order.write_text(json.dumps({"manifest": manifest}))
            log = root / ("h-%s-%s.log" % (slug, local_flag))
            script = r'''
source "$REPO/bin/cfw-render-harness.sh"
cr_log() { printf '%s\n' "$*" >> "$LOG"; }
CR_H_ORDER_DIR="$ORDER_DIR"
CR_H_RECIPE_DIR="$RECIPE"
CR_H_LOCAL="$LOCAL"
: > "$LOG"
seal_rc=0
cr_h_seal_prior_loudness final_checks "$WD" || seal_rc=$?
prompt_rc=0
cr_h_build_prompt final_checks "$WD" "$ORDER" || prompt_rc=$?
printf 'SEAL=%s\nPROMPT=%s\n' "$seal_rc" "$prompt_rc"
'''
            env = os.environ.copy()
            env.update({
                "REPO": str(repo),
                "ORDER_DIR": str(order_dir),
                "RECIPE": str(recipe_dir),
                "WD": str(wd),
                "ORDER": str(order),
                "LOG": str(log),
                "LOCAL": local_flag,
                "CFW_RENDER_SKILLS_DIR": skills,
            })
            h = run_bash(script, env, 180)
            if h.returncode != 0 or "SEAL=0" not in h.stdout or "PROMPT=0" not in h.stdout:
                problems.append("%s harness seal/prompt failed: %s" % (label, (h.stdout + h.stderr)[-500:]))
                continue
            sealed = last_lufs(wd / "prior" / "assembled_video.mp4")
            if sealed is None or not (-15.5 <= sealed <= -12.5):
                problems.append("%s prior sealed loudness %s" % (label, sealed))
                continue
            prompt = (wd / "prompt.md").read_text() if (wd / "prompt.md").is_file() else ""
            if "OUT_RAW=prior/assembled_video.mp4" not in prompt or "eval-run.sh" not in prompt or "concat-cover.txt" not in prompt:
                problems.append("%s prompt is not the real final_checks step" % label)
                continue
            evidence = "Required local QA evidence" in prompt
            if local_flag == "1" and slug == "p-reels-spotlight":
                if not evidence:
                    problems.append("%s local spotlight prompt missing QA evidence" % label)
            elif evidence:
                problems.append("%s prompt includes local QA evidence" % label)
            setup = one_block(prompt, lambda b: "OUT_RAW=prior/assembled_video.mp4" in b and "concat-cover.txt" not in b, label + " setup")
            cover = one_block(prompt, lambda b: "concat-cover.txt" in b and "saves/final_video.mp4" in b, label + " cover")
            gate = one_block(prompt, lambda b: "eval-run.sh" in b and "saves/final_video.mp4" in b, label + " eval")
            if not setup or not cover or not gate:
                continue
            step = wd / "step-order.sh"
            step.write_text("#!/bin/bash\nset -eu\n" + setup + "\n" + cover + "\nset +e\n" + gate + "\nexit 0\n")
            ran = subprocess.run(
                ["bash", "--noprofile", "--norc", str(step)],
                cwd=str(wd), capture_output=True, text=True, env=env, timeout=240)
            report = wd / "saves" / "eval" / "qa" / "qa-report.txt"
            if not (wd / "saves" / "final_video.mp4").is_file() or not report.is_file():
                problems.append("%s step order did not score: %s" % (label, (ran.stdout + ran.stderr)[-500:]))
                continue
            loud_lines = [ln for ln in report.read_text().splitlines() if "loudness" in ln.lower()]
            first = loud_lines[0] if loud_lines else ""
            if "[PASS]" not in first or "[FAIL]" in first:
                problems.append("%s first loudness line is not PASS (prior %s): %s" % (label, sealed, first or report.read_text()[-400:]))

    # A real loudnorm failure on the prior is reported. A placeholder is skipped.
    wrap = root / "wrap"
    wrap.mkdir()
    (wrap / "python3").write_text(
        "#!/bin/sh\nfor a in \"$@\"; do\n"
        "  if [ \"$a\" = \"loudnorm\" ]; then echo \"loudnorm encoder failed\"; exit 1; fi\ndone\n"
        "exec \"%s\" \"$@\"\n" % sys.executable)
    os.chmod(wrap / "python3", 0o755)
    fail_wd = root / "fail-prior"
    (fail_wd / "prior").mkdir(parents=True)
    shutil.copy(src, fail_wd / "prior" / "assembled_video.mp4")
    ph_wd = root / "ph-prior"
    (ph_wd / "prior").mkdir(parents=True)
    (ph_wd / "prior" / "assembled_video.mp4").write_text("placeholder\n")
    probe_order = root / "probe-order"
    probe_order.mkdir()
    (probe_order / "order.json").write_text(json.dumps({"manifest": {"recipe": "p-reels-pip"}}))
    probe_log = root / "probe.log"
    probe = r'''
source "$REPO/bin/cfw-render-harness.sh"
cr_log() { printf '%s\n' "$*" >> "$LOG"; }
export PATH="$WRAP:$PATH"
CR_H_ORDER_DIR="$ORDER_DIR"
CR_H_RECIPE_DIR="$RECIPE"
CR_H_LOCAL=0
: > "$LOG"
fail_rc=0
cr_h_seal_prior_loudness final_checks "$FAIL_WD" || fail_rc=$?
fail_log="$(cat "$LOG")"
: > "$LOG"
place_rc=0
cr_h_seal_prior_loudness final_checks "$PH_WD" || place_rc=$?
place_log="$(cat "$LOG")"
printf 'FAIL=%s\nPLACE=%s\n' "$fail_rc" "$place_rc"
printf 'FAIL_LOG=%s\n' "$fail_log"
printf 'PLACE_LOG=%s\n' "$place_log"
'''
    probe_env = os.environ.copy()
    probe_env.update({
        "REPO": str(repo),
        "WRAP": str(wrap),
        "ORDER_DIR": str(probe_order),
        "RECIPE": str(repo / "skills" / "p-reels-pip"),
        "FAIL_WD": str(fail_wd),
        "PH_WD": str(ph_wd),
        "LOG": str(probe_log),
        "PATH": str(wrap) + os.pathsep + probe_env.get("PATH", ""),
    })
    probed = run_bash(probe, probe_env, 60)
    fields = {}
    for line in probed.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key] = value
    if fields.get("FAIL") != "1" or "final loudness normalisation failed" not in fields.get("FAIL_LOG", ""):
        problems.append("prior seal hid a real failure: %s" % (fields or (probed.stdout + probed.stderr)[-400:]))
    if "loudnorm encoder failed" not in fields.get("FAIL_LOG", ""):
        problems.append("prior seal log dropped the tool error: %s" % fields.get("FAIL_LOG"))
    if fields.get("PLACE") != "0" or "normalisation failed" in fields.get("PLACE_LOG", ""):
        problems.append("placeholder prior was not skipped: %s" % fields)

print("ok" if not problems else "; ".join(problems))
raise SystemExit(0 if not problems else 1)
PY
)"
wi262_rc=$?
if [[ "$wi262_rc" == "0" && "$wi262_detail" == "ok" ]]; then
  pass "WI2.62: harness seals the quiet prior so the step-doc concat gate loudness is PASS"
else
  fail "WI2.62 pre-score loudness seal" "$wi262_detail"
fi

echo "=== Case 44: WI2.63 — reel complete uploads final_video then cover, never step videos ==="
# Smoke 20b reached Reviews with outputUrl = voice_track.mp4 because the harness
# listed every save in step order and report.sh sets outputUrl from urls[0].
# Run the real harness, selector and complete path for both reel recipes.
# Fixture bytes make a renamed intermediate obvious. Step progress uploads are
# not the Reviews list; only the complete upload log is.
wi263_delivery() {
  local slug="$1" root recipe h_rc=0 complete_rc=0 captions="" f role
  local -a files=()
  root="$(mktemp -d)"
  recipe="$REPO_DIR/skills/$slug"
  mkdir -p "$root/fixtures" "$root/bin" "$root/state" "$root/logs"
  printf 'voice-track-fixture\n' > "$root/fixtures/voice_track.mp4"
  printf 'assembled-fixture\n' > "$root/fixtures/assembled_video.mp4"
  printf 'scenes-fixture\n' > "$root/fixtures/rendered_scenes.mp4"
  printf 'background-fixture\n' > "$root/fixtures/background.mp4"
  printf 'final-video-fixture\n' > "$root/fixtures/final_video.mp4"
  printf 'cover-fixture\n' > "$root/fixtures/cover.png"
  python3 - "$root/engine.sh" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text("""#!/usr/bin/env bash
set -eu
cat >/dev/null
mkdir -p saves
for sv in ${CFW_STEP_SAVES:-}; do
  sid="${sv%%:*}"
  ext="${sv##*:}"
  dest="saves/${sid}.${ext}"
  src="${WI263_FIXTURES}/${sid}.${ext}"
  if [[ -f "$src" ]]; then
    cp "$src" "$dest"
  elif [[ "$sid" == captions ]]; then
    printf '%s\\n' '{"instagram":"Reel caption","default":"Reel caption"}' > "$dest"
  else
    printf 'side %s\\n' "$sid" > "$dest"
  fi
done
""")
PY
  chmod +x "$root/engine.sh"
  python3 - "$root/order.json" "$recipe/manifest.json" "$slug" <<'PY'
import json, sys
dest, man_path, slug = sys.argv[1:]
man = json.load(open(man_path))
json.dump({
    "id": "order-wi263-" + slug,
    "attempt": {"id": "att-wi263"},
    "recipe": slug,
    "kind": "video",
    "taskOrder": {},
    "inputs": {},
    "manifest": man,
}, open(dest, "w"))
PY
  (
    export CFW_RENDER_LOG_DIR="$root/logs"
    export CFW_RENDER_STATE_DIR="$root/state"
    export CFW_RENDER_ENGINE=codex
    export CFW_RENDER_ENGINE_CMD="$root/engine.sh"
    export WI263_FIXTURES="$root/fixtures"
    export CFW_WORKER_ID="w-wi263"
    export CFW_ORDER_ID="order-wi263-$slug"
    export CFW_API_BASE="http://127.0.0.1:9"
    export CFW_RENDER_WORKER_KEY="cfw_render_wi263testkey0000"
    export CFW_RENDER_HEARTBEAT_SEC=30
    export CFW_RENDER_STEP_TIMEOUT_SEC=60
    unset CFW_RENDER_SKILLS_DIR
    unset CFW_RENDER_LOCAL_CHECKPOINTS
    # shellcheck disable=SC1091
    source "$REPO_DIR/bin/cfw-render-lib.sh"
    source "$REPO_DIR/bin/cfw-render-engine.sh"
    source "$REPO_DIR/bin/cfw-render-harness.sh"
    cr_harness_heartbeat_start() { :; }
    cr_harness_heartbeat_stop() { :; }
    cr_h_run_with_timeout() { shift; "$@"; }
    cr_report_step() { printf '%s' '{"ok":true,"directive":"continue"}'; }
    cr_h_upload_with_retry() { printf 'https://media.cfw.social/step-%s' "$(basename "$1")"; }
    cr_engine_limit_detect() { return 1; }
    cr_harness_run "$root/order.json" "$root" "$recipe" >"$root/harness.out" 2>"$root/harness.err"
  )
  h_rc=$?
  if [[ "$h_rc" != "0" ]]; then
    python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); t=p.read_text(errors="replace") if p.is_file() else ""; print(t[-500:].replace("\n"," | "))' "$root/harness.err" > "$root/err-tail.txt"
    python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); t=p.read_text(errors="replace") if p.is_file() else ""; print(t[:300].replace("\n"," | "))' "$root/harness.out" > "$root/out-head.txt"
    printf 'harness rc %s out=%s err=%s' "$h_rc" "$(cat "$root/out-head.txt")" "$(cat "$root/err-tail.txt")"
    rm -rf "$root"
    return 0
  fi
  sel="$(
    # shellcheck disable=SC1091
    source "$REPO_DIR/bin/cfw-render-lib.sh"
    cr_select_deliverables "$root" "$(cat "$root/harness.out")"
  )"
  printf '%s\n' "$sel" > "$root/select.txt"
  while IFS=$'\t' read -r f role; do
    [[ -n "$f" ]] || continue
    if [[ "$role" == "captions" ]]; then captions="$f"; else files+=("$f"); fi
  done < "$root/select.txt"
  cp "$REPO_DIR/bin/cfw-render-report.sh" "$root/bin/cfw-render-report.sh"
  cp "$REPO_DIR/bin/cfw-render-lib.sh" "$root/bin/cfw-render-lib.sh"
  cat >> "$root/bin/cfw-render-lib.sh" <<EOF
cr_mcp_call() {
  printf '%s\n' "\$2" >> "$root/calls.jsonl"
  printf '{"ok":true}'
}
EOF
  python3 - "$root/bin/cfw-render-upload.sh" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text("""#!/usr/bin/env bash
set -eu
line=""
IFS= read -r line < "$1" || true
printf '%s\\t%s\\n' "$(basename "$1")" "$line" >> "$WI263_UPLOADS"
printf 'https://media.cfw.social/%s\\n' "$(basename "$1")"
""")
PY
  chmod +x "$root/bin/cfw-render-upload.sh"
  if (( ${#files[@]} > 0 )); then
    (
      cd "$root" || exit 1
      export CFW_ORDER_ID="order-wi263-$slug" CFW_WORKER_ID="w-wi263" CFW_ATTEMPT_ID="att-wi263"
      export CFW_API_BASE="http://127.0.0.1:9" CFW_RENDER_WORKER_KEY="cfw_render_wi263testkey0000"
      export CFW_RENDER_DIRECTOR_MODEL="sonnet"
      export CFW_CAPTIONS_FILE="$captions"
      export WI263_UPLOADS="$root/uploads.txt"
      unset CFW_RENDER_KEEP_DIR
      PATH="$root/bin:$PATH"
      bash "$root/bin/cfw-render-report.sh" complete "${files[@]}"
    ) >"$root/complete.out" 2>"$root/complete.err" || complete_rc=$?
  else
    printf 'no media from select\n' > "$root/complete.err"
    complete_rc=2
  fi
  printf '%s\n' "$complete_rc" > "$root/complete.rc"
  python3 - "$root" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
bad = []
harness_err = ""
err_path = root / "harness.err"
if err_path.is_file():
    harness_err = err_path.read_text(errors="replace")[-400:].replace("\n", " | ")
complete_err = ""
cerr = root / "complete.err"
if cerr.is_file():
    complete_err = cerr.read_text(errors="replace")[-400:].replace("\n", " | ")
try:
    items = json.loads((root / "harness.out").read_text())
except Exception as exc:
    bad.append("harness json %s; err=%s" % (exc, harness_err))
    items = None
if isinstance(items, list):
    ids = [i.get("id") for i in items if isinstance(i, dict)]
    if ids != ["final_video", "cover", "captions"]:
        bad.append("ids=%r err=%s" % (ids, harness_err))
    by_id = {i.get("id"): i for i in items if isinstance(i, dict)}
    for sid, needle in (("final_video", "final-video-fixture"), ("cover", "cover-fixture")):
        item = by_id.get(sid) or {}
        path = item.get("path") or ""
        if "/steps/final_checks/saves/" not in path:
            bad.append("%s path=%r" % (sid, path))
        else:
            lines = pathlib.Path(path).read_text(errors="replace").splitlines()
            got = lines[0] if lines else ""
            if got != needle:
                bad.append("%s bytes=%r" % (sid, got))
    blob = json.dumps(items)
    for name in ("voice_track", "assembled_video", "rendered_scenes", "background"):
        if name in blob:
            bad.append("harness leaked %s" % name)
uploads = (root / "uploads.txt").read_text(errors="replace") if (root / "uploads.txt").is_file() else ""
want_lines = ["final_video.mp4\tfinal-video-fixture", "cover.png\tcover-fixture"]
if uploads.splitlines() != want_lines:
    bad.append("uploads=%r complete=%s" % (uploads.splitlines(), complete_err))
for banned in ("voice_track", "assembled_video", "rendered_scenes", "background", "captions.json"):
    if banned in uploads:
        bad.append("upload leaked %s" % banned)
calls_path = root / "calls.jsonl"
if not calls_path.is_file() or not calls_path.read_text().strip():
    bad.append("no complete call; complete=%s" % complete_err)
else:
    rows = [json.loads(line) for line in calls_path.read_text().splitlines() if line.strip()]
    if len(rows) != 1:
        bad.append("calls=%d" % len(rows))
    else:
        data = rows[0]
        url = data.get("outputUrl") or ""
        if not str(url).endswith("/final_video.mp4"):
            bad.append("outputUrl=%r" % url)
        names = [u.split("/")[-1].split("?")[0] for u in data.get("outputUrls") or []]
        if names != ["final_video.mp4", "cover.png"]:
            bad.append("outputUrls=%r" % names)
        roles = [o.get("role") for o in data.get("outputs") or []]
        kinds = [o.get("kind") for o in data.get("outputs") or []]
        if roles != ["cover", "poster"]:
            bad.append("roles=%r" % roles)
        if kinds != ["video", "image"]:
            bad.append("kinds=%r" % kinds)
        caps = data.get("captions") or {}
        if caps.get("instagram") != "Reel caption":
            bad.append("captions=%r" % caps)
print("ok" if not bad else "; ".join(bad))
PY
  rm -rf "$root"
}

for wi263_slug in p-reels-spotlight p-reels-pip; do
  wi263_detail="$(wi263_delivery "$wi263_slug")"
  if [[ "$wi263_detail" == "ok" ]]; then
    if [[ "$wi263_slug" == "p-reels-spotlight" ]]; then
      pass "WI2.63 spotlight: delivery uploads final_video then cover, no voice_track or assembled or scenes"
    else
      pass "WI2.63 pip: delivery uploads final_video then cover, no voice_track, assembled or background"
    fi
  else
    fail "WI2.63 $wi263_slug delivery" "$wi263_detail"
  fi
done

wi263_guard="$(python3 - "$REPO_DIR" <<'PY'
import os, subprocess, sys, pathlib, tempfile, json, textwrap
repo = pathlib.Path(sys.argv[1])
script = r'''
set -u
source "$REPO/bin/cfw-render-harness.sh"
got="$(cr_h_reel_delivery_outputs "$ORDER" "$RAW" "$RECIPE")"
printf '%s\n---\n' "$got"
got2="$(cr_h_reel_delivery_outputs "$SPOT" "$MISSING" "$SPOT_RECIPE")"
printf '%s' "$got2"
'''
raw = '[{"id":"voice_track","path":"/order/voice_track.mp4"},{"id":"final_video","path":"/order/final_video.mp4"}]'
missing = '[{"id":"voice_track","path":"/s/voice_track.mp4"},{"id":"final_video","path":"/s/final_video.mp4"},{"id":"captions","path":"/s/captions.json"}]'
with tempfile.TemporaryDirectory(prefix="wi263-guard-") as tmp:
    root = pathlib.Path(tmp)
    order = root / "carousel.json"
    order.write_text(json.dumps({"recipe": "p-carousel", "manifest": {"recipe": "p-carousel"}}))
    spot = root / "spot.json"
    spot.write_text(json.dumps({"manifest": {"recipe": "p-reels-spotlight"}}))
    env = os.environ.copy()
    env.update({
        "REPO": str(repo),
        "ORDER": str(order),
        "RAW": raw,
        "RECIPE": str(repo / "skills" / "p-carousel"),
        "SPOT": str(spot),
        "MISSING": missing,
        "SPOT_RECIPE": str(repo / "skills" / "p-reels-spotlight"),
    })
    proc = subprocess.run(["bash", "--noprofile", "--norc", "-c", script], capture_output=True, text=True, env=env, timeout=60)
parts = proc.stdout.split("\n---\n", 1)
bad = []
if proc.returncode != 0:
    bad.append("guard rc %s %s" % (proc.returncode, proc.stderr[-300:].replace("\n", " | ")))
elif len(parts) != 2:
    bad.append("guard shape %r" % proc.stdout[:300])
else:
    if parts[0] != raw:
        bad.append("non-reel changed to %r" % parts[0][:300])
    want = '[{"id":"captions","path":"/s/captions.json"}]'
    if parts[1] != want:
        bad.append("missing cover delivered %r" % parts[1][:300])
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi263_guard" == "ok" ]]; then
  pass "WI2.63: non-reel harness output is left in caller order"
  pass "WI2.63: reel missing its cover does not deliver a step video"
else
  fail "WI2.63 non-reel and missing-cover delivery" "$wi263_guard"
fi

echo "=== Case 45: WI2.64 — pip last frame stays bright and captions stop before the CTA ==="
wi264_rc=0
wi264_out="$(python3 - "$REPO_DIR" <<'PY'
import hashlib, importlib.util, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

repo = Path(sys.argv[1])
rows = []

def add(name, detail=""):
    rows.append((name, detail.replace("\n", " | ").replace("\t", " ")[:900]))

def sha256_file(path):
    return "sha256:" + hashlib.sha256(Path(path).read_bytes()).hexdigest()

def recipe_checksum(recipe):
    base = repo / "skills" / recipe
    rels = []
    for path in base.rglob("*"):
        if path.is_file() and path.name not in {".DS_Store", "__pycache__", ".git", ".hub"}:
            rels.append(str(path.relative_to(base)).replace("\\", "/"))
    rels = sorted(rels)
    blob = "\n".join("%s=%s" % (rel, sha256_file(base / rel)) for rel in rels)
    return "sha256:" + hashlib.sha256(blob.encode("utf-8")).hexdigest()

pip_md = (repo / "skills/p-reels-pip/steps/05-composite.md").read_text(encoding="utf-8")
hey_md = (repo / "skills/p-reels-pip-heygen/steps/05-composite.md").read_text(encoding="utf-8")
pip_hash = sha256_file(repo / "skills/p-reels-pip/steps/05-composite.md")
hey_hash = sha256_file(repo / "skills/p-reels-pip-heygen/steps/05-composite.md")
sys.stderr.write("WI2.64-HASH p-reels-pip steps/05-composite.md %s\n" % pip_hash)
sys.stderr.write("WI2.64-HASH p-reels-pip-heygen steps/05-composite.md %s\n" % hey_hash)
sys.stderr.write("WI2.64-CHECKSUM p-reels-pip %s\n" % recipe_checksum("p-reels-pip"))
sys.stderr.write("WI2.64-CHECKSUM p-reels-pip-heygen %s\n" % recipe_checksum("p-reels-pip-heygen"))
sys.stderr.flush()

def extract(text, name):
    marker = "cat > work/%s <<'PY'\n" % name
    start = text.index(marker) + len(marker)
    end = text.index("\nPY\n", start)
    return text[start:end] + "\n"

def run_ff(cwd, args):
    proc = subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", *args],
        cwd=cwd, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError("ffmpeg %s :: %s" % (" ".join(args[:8]), (proc.stderr or "")[-400:]))

def probe_durs(path):
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type,duration", "-of", "json", str(path)],
        capture_output=True, text=True,
    )
    data = json.loads(proc.stdout or "{}")
    fmt = float((data.get("format") or {}).get("duration") or 0)
    vid = None
    for st in data.get("streams") or []:
        if st.get("codec_type") == "video" and st.get("duration") not in (None, "N/A", ""):
            vid = float(st["duration"])
    return fmt, vid

def last_yavg(path):
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostats", "-sseof", "-0.2", "-i", str(path),
         "-vf", "signalstats,metadata=print:key=lavfi.signalstats.YAVG", "-an", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    vals = re.findall(r"lavfi\.signalstats\.YAVG=([0-9.]+)", (proc.stderr or "") + "\n" + (proc.stdout or ""))
    return float(vals[-1]) if vals else None

def hold(script, video, target=None):
    cmd = [sys.executable, script, str(video)]
    if target is not None:
        cmd.append("%.3f" % target)
    return subprocess.run(cmd, capture_output=True, text=True)

try:
    if pip_md != hey_md:
        add("WI2.64 pip and heygen composite match", "byte mismatch len %d vs %d" % (len(pip_md), len(hey_md)))
    else:
        add("WI2.64 pip and heygen composite match")
    hub = repo / "skills/p-reels-pip-heygen/.hub/p-reels-pip/steps/05-composite.md"
    hub_hash = sha256_file(hub)
    if hub_hash != "sha256:ff6d3d1e0e2e903446264955c9f40fdde3f3db2033d30ce4bea5ae2ab37dbabe":
        add("WI2.64 heygen hub composite left for sync", hub_hash)
    else:
        add("WI2.64 heygen hub composite left for sync")
    if "itsoffset \"$CTA_START\"" in pip_md:
        add("WI2.64 bundled composite drops itsoffset", "itsoffset still present")
    else:
        add("WI2.64 bundled composite drops itsoffset")

    spec = importlib.util.spec_from_file_location("sync_skills_wi264", repo / "scripts/sync-skills.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    # WI2.79: the caption-phrase P1 note replaces the hunk's first line; its inverse gives it back
    note_count = pip_md.count(mod._CAPTION_PHRASES_PIP_P1_NOTE)
    base_md = pip_md.replace(mod._CAPTION_PHRASES_PIP_P1_NOTE, mod._CAPTION_PHRASES_PIP_P1_ANCHOR, 1)
    inverted = base_md
    invert_bad = "" if note_count == 1 else "WI2.79 P1 note count %d" % note_count
    for old, new in reversed(mod.P_REELS_PIP_TAIL_PAIRS):
        if invert_bad:
            break
        count = inverted.count(new)
        if count != 1:
            invert_bad = "hunk count %d for %r" % (count, new[:80])
            break
        inverted = inverted.replace(new, old, 1)
    if invert_bad:
        add("WI2.64 sync transform reproduces the bundled composite", invert_bad)
    elif 'itsoffset "$CTA_START"' not in inverted:
        add("WI2.64 sync transform reproduces the bundled composite", "inverted text has no itsoffset overlay")
    else:
        with tempfile.TemporaryDirectory(prefix="wi264-tx-") as tmp:
            root = Path(tmp)
            recipe = root / "recipe"
            (recipe / "steps").mkdir(parents=True)
            target = recipe / "steps/05-composite.md"
            target.write_text(inverted, encoding="utf-8")
            mod.apply_p_reels_pip_tail(recipe)
            got = target.read_text(encoding="utf-8")
            mod.apply_p_reels_pip_tail(recipe)
            again = target.read_text(encoding="utf-8")
            if got != base_md:
                pos = next((i for i, (a, b) in enumerate(zip(got, base_md)) if a != b), min(len(got), len(base_md)))
                add("WI2.64 sync transform reproduces the bundled composite",
                    "at %d got %r want %r lens %d/%d" % (pos, got[max(0, pos-60):pos+60], base_md[max(0, pos-60):pos+60], len(got), len(base_md)))
            elif again != base_md:
                add("WI2.64 sync transform reproduces the bundled composite", "second apply changed bytes")
            else:
                add("WI2.64 sync transform reproduces the bundled composite")
                src = root / "src"
                for name, deps in (("p-reels-pip", "[]"), ("p-reels-pip-heygen", "[p-reels-pip]")):
                    steps = src / name / "steps"
                    steps.mkdir(parents=True)
                    (src / name / "SKILL.md").write_text(
                        "---\nname: %s\ndependsOn: %s\n---\n# %s\n" % (name, deps, name),
                        encoding="utf-8",
                    )
                    (steps / "05-composite.md").write_text(inverted, encoding="utf-8")
                recipes = root / "recipes.json"
                recipes.write_text(json.dumps({
                    "source": "test-wi264",
                    "recipes": [
                        {"name": "p-reels-pip", "version": "1.0.0", "providers": []},
                        {"name": "p-reels-pip-heygen", "version": "1.0.0", "providers": []},
                    ],
                }), encoding="utf-8")
                out = root / "out"
                env = os.environ.copy()
                env["CFW_SKILLS_SRC"] = str(src)
                proc = subprocess.run(
                    ["bash", str(repo / "scripts/sync-skills.sh"), "--recipes", str(recipes),
                     "--out-dir", str(out), "--skip-manifest"],
                    capture_output=True, text=True, env=env,
                )
                paths = [
                    out / "p-reels-pip/steps/05-composite.md",
                    out / "p-reels-pip-heygen/steps/05-composite.md",
                    out / "p-reels-pip-heygen/.hub/p-reels-pip/steps/05-composite.md",
                ]
                bad_sync = []
                if proc.returncode != 0:
                    bad_sync.append("rc %s %s" % (proc.returncode, (proc.stderr or proc.stdout or "")[-400:]))
                for path in paths:
                    # top-level steps also get the WI2.76+ caption-phrase note; the hub copy does not
                    want = base_md if ".hub" in path.parts else pip_md
                    if not path.is_file():
                        bad_sync.append("missing %s" % path.name)
                    elif path.read_text(encoding="utf-8") != want:
                        bad_sync.append("diff %s" % path.relative_to(out))
                if bad_sync:
                    add("WI2.64 sync-skills.sh re-applies the pip tail on both recipes and the hub copy", "; ".join(bad_sync))
                else:
                    add("WI2.64 sync-skills.sh re-applies the pip tail on both recipes and the hub copy")

    hold_src = extract(pip_md, "hold_tail.py")
    clamp_src = extract(pip_md, "clamp_captions.py")
    with tempfile.TemporaryDirectory(prefix="wi264-pic-") as tmp:
        d = Path(tmp)
        (d / "work").mkdir()
        script = d / "hold_tail.py"
        script.write_text(hold_src, encoding="utf-8")
        clamp = d / "clamp_captions.py"
        clamp.write_text(clamp_src, encoding="utf-8")

        run_ff(d, ["-f", "lavfi", "-i", "color=c=white:s=160x160:r=30:d=2",
                   "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=2",
                   "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", "vid.mp4"])
        run_ff(d, ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2.4",
                   "-c:a", "aac", "tone.m4a"])
        run_ff(d, ["-i", "vid.mp4", "-i", "tone.m4a", "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "short.mp4"])
        before_fmt, before_vid = probe_durs(d / "short.mp4")
        proc = hold(str(script), d / "short.mp4", 2.4)
        fmt, vid = probe_durs(d / "short.mp4")
        y = last_yavg(d / "short.mp4")
        detail = "before fmt %.3f vid %s after fmt %.3f vid %s y %s err %s" % (
            before_fmt, before_vid, fmt, vid, y, (proc.stderr or "")[-240:])
        if proc.returncode != 0 or before_vid is None or before_vid > before_fmt - 0.2:
            add("WI2.64 short picture is held out to the bright bed", detail)
        elif y is None or y <= 30 or abs(fmt - 2.4) > 0.15 or vid is None or abs(vid - fmt) > 0.1:
            add("WI2.64 short picture is held out to the bright bed", detail)
        else:
            add("WI2.64 short picture is held out to the bright bed")

        run_ff(d, ["-f", "lavfi", "-i", "color=c=white:s=160x160:r=30:d=2",
                   "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
                   "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", "bright.mp4"])
        run_ff(d, ["-f", "lavfi", "-i", "color=c=black:s=160x160:r=30:d=0.4",
                   "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.4",
                   "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", "black.mp4"])
        (d / "list.txt").write_text("file 'bright.mp4'\nfile 'black.mp4'\n", encoding="utf-8")
        run_ff(d, ["-f", "concat", "-safe", "0", "-i", "list.txt",
                   "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", "tailed.mp4"])
        tail_before = last_yavg(d / "tailed.mp4")
        orig_fmt, _orig_vid = probe_durs(d / "tailed.mp4")
        proc = hold(str(script), d / "tailed.mp4")
        fmt, vid = probe_durs(d / "tailed.mp4")
        y = last_yavg(d / "tailed.mp4")
        detail = "tail before %s after y %s fmt %.3f->%.3f vid %s err %s" % (
            tail_before, y, orig_fmt, fmt, vid, (proc.stderr or "")[-240:])
        if proc.returncode != 0 or tail_before is None or tail_before > 16:
            add("WI2.64 encoded black tail is replaced with the last bright frame", detail)
        elif y is None or y <= 30 or abs(fmt - orig_fmt) > 0.15 or vid is None or abs(vid - fmt) > 0.1:
            add("WI2.64 encoded black tail is replaced with the last bright frame", detail)
        else:
            add("WI2.64 encoded black tail is replaced with the last bright frame")

        run_ff(d, ["-f", "lavfi", "-i", "color=c=white:s=160x160:r=30:d=2",
                   "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2",
                   "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
                   "work/composed.mp4"])
        run_ff(d, ["-f", "lavfi", "-i", "color=c=white:s=160x160:r=30:d=0.2",
                   "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", "-an", "cta-w.mp4"])
        run_ff(d, ["-f", "lavfi", "-i", "color=c=black:s=160x160:r=30:d=0.8",
                   "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", "-an", "cta-b.mp4"])
        (d / "cta-list.txt").write_text("file 'cta-w.mp4'\nfile 'cta-b.mp4'\n", encoding="utf-8")
        run_ff(d, ["-f", "concat", "-safe", "0", "-i", "cta-list.txt",
                   "-c:v", "libx264", "-qp", "0", "-pix_fmt", "yuv420p", "work/cta-card.mov"])
        marker = "ffmpeg -y -i work/composed.mp4 -i work/cta-card.mov"
        start = pip_md.index(marker)
        end = pip_md.index("work/with-cta.mp4", start) + len("work/with-cta.mp4")
        overlay = pip_md[start:end]
        shell = "set -e\nBED_DUR=2\nCTA_DURATION=0.2\nCTA_START=1.8\n" + overlay + "\n"
        proc = subprocess.run(["bash", "-c", shell], cwd=d, capture_output=True, text=True)
        if proc.returncode != 0:
            add("WI2.64 CTA overlay stops at the bed without a black frame", (proc.stderr or "")[-400:])
        else:
            held = hold(str(script), d / "work/with-cta.mp4", 2.0)
            fmt, vid = probe_durs(d / "work/with-cta.mp4")
            y = last_yavg(d / "work/with-cta.mp4")
            detail = "fmt %.3f vid %s y %s err %s" % (fmt, vid, y, (held.stderr or proc.stderr or "")[-240:])
            if held.returncode != 0 or y is None or y <= 30 or abs(fmt - 2.0) > 0.15 or vid is None or abs(vid - fmt) > 0.1:
                add("WI2.64 CTA overlay stops at the bed without a black frame", detail)
            else:
                add("WI2.64 CTA overlay stops at the bed without a black frame")

        window = d / "cta-window.json"
        window.write_text(json.dumps({"cta_start": 3.0, "bed_dur": 6.0}), encoding="utf-8")
        words_src = d / "transcripts.json"
        words_src.write_text(json.dumps({"words": [
            {"text": "Hello", "start": 0.2, "end": 1.0},
            {"text": "still", "start": 2.5, "end": 3.4},
            {"text": "edge", "start": 3.0, "end": 3.2},
            {"text": "late", "start": 3.2, "end": 4.0},
        ]}), encoding="utf-8")
        plan_path = d / "plan.json"
        plan_path.write_text(json.dumps({
            "caption_groups": [
                {"start": 0.2, "end": 1.0, "words": [{"w": "Hello", "s": 0.2, "e": 1.0}]},
                {"start": 2.5, "end": 3.4, "words": [{"w": "still", "s": 2.5, "e": 3.4}]},
                {"start": 3.2, "end": 4.0, "words": [{"w": "over", "s": 3.2, "e": 4.0}]},
            ],
            "sfx": [{"id": "whoosh", "start": 3.5, "end": 4.0}],
        }), encoding="utf-8")
        env = os.environ.copy()
        env["CTA_WINDOW"] = str(window)
        words_out = d / "words.json"
        wproc = subprocess.run([sys.executable, str(clamp), "words", str(words_src), str(words_out)],
                               capture_output=True, text=True, env=env)
        pproc = subprocess.run([sys.executable, str(clamp), "plan", str(plan_path)],
                               capture_output=True, text=True, env=env)
        words = json.loads(words_out.read_text(encoding="utf-8")) if words_out.is_file() else []
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
        groups = plan.get("caption_groups") or []
        cue_bad = []
        for row in words:
            if float(row["start"]) >= 3.0 - 1e-3 or float(row["end"]) > 3.0 + 1e-6:
                cue_bad.append("word %s" % row)
        for g in groups:
            if float(g["start"]) >= 3.0 - 1e-3 or float(g["end"]) > 3.0 + 1e-6:
                cue_bad.append("group %s" % g.get("start"))
            for w in g.get("words") or []:
                if float(w["s"]) >= 3.0 - 1e-3 or float(w["e"]) > 3.0 + 1e-6:
                    cue_bad.append("plan word %s" % w)
        sfx = plan.get("sfx") or []
        if wproc.returncode != 0 or pproc.returncode != 0 or cue_bad or len(words) != 2 or len(groups) != 2:
            add("WI2.64 caption cues stop at the CTA window",
                "rc %s/%s cues %s words %s groups %s" % (wproc.returncode, pproc.returncode, cue_bad, words, groups))
        elif not sfx or sfx[0].get("start") != 3.5:
            add("WI2.64 caption cues stop at the CTA window", "sfx changed %s" % sfx)
        else:
            add("WI2.64 caption cues stop at the CTA window")
        off = d / "cta-off.json"
        off.write_text(json.dumps({"cta_start": None, "bed_dur": 6.0}), encoding="utf-8")
        env["CTA_WINDOW"] = str(off)
        off_words = d / "words-off.json"
        off_src = d / "transcripts-off.json"
        shutil.copyfile(words_src, off_src)
        oproc = subprocess.run([sys.executable, str(clamp), "words", str(off_src), str(off_words)],
                               capture_output=True, text=True, env=env)
        kept = json.loads(off_words.read_text(encoding="utf-8")) if off_words.is_file() else []
        if oproc.returncode != 0 or len(kept) != 4:
            add("WI2.64 card off leaves caption cues unchanged", "rc %s n %s" % (oproc.returncode, len(kept)))
        else:
            add("WI2.64 card off leaves caption cues unchanged")
except Exception as exc:
    add("WI2.64 pip tail harness", "%s: %s" % (type(exc).__name__, exc))

for name, detail in rows:
    if detail:
        print("BAD\t%s\t%s" % (name, detail))
    else:
        print("OK\t%s\t." % (name,))
PY
)" || wi264_rc=$?
if [[ "$wi264_rc" != "0" ]]; then
  fail "WI2.64 pip tail harness" "python exited $wi264_rc"
fi
while IFS=$'\t' read -r status name detail; do
  [[ -z "${status:-}" ]] && continue
  if [[ "$status" == "OK" ]]; then
    pass "$name"
  else
    fail "$name" "$detail"
  fi
done <<EOF
$wi264_out
EOF

echo "=== Case 46: WI2.68 — reel whisper model id is whisper-small-mlx ==="
wi268_rc=0
wi268_out="$(python3 - "$REPO_DIR" <<'PY'
import hashlib, importlib.util, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

repo = Path(sys.argv[1])
rows = []

def add(name, detail=""):
    rows.append((name, detail.replace("\n", " | ").replace("\t", " ")[:900]))

def sha256_file(path):
    return "sha256:" + hashlib.sha256(Path(path).read_bytes()).hexdigest()

def recipe_checksum(recipe):
    base = repo / "skills" / recipe
    rels = []
    for path in base.rglob("*"):
        if path.is_file() and path.name not in {".DS_Store", "__pycache__", ".git", ".hub"}:
            rels.append(str(path.relative_to(base)).replace("\\", "/"))
    rels = sorted(rels)
    blob = "\n".join("%s=%s" % (rel, sha256_file(base / rel)) for rel in rels)
    return "sha256:" + hashlib.sha256(blob.encode("utf-8")).hexdigest()

BAD = "mlx-community/whisper-small"
GOOD = "mlx-community/whisper-small-mlx"
BAD_RE = re.compile(r"mlx-community/whisper-small(?!-mlx)")

EDITED = [
    "skills/p-reels-pip/SKILL.md",
    "skills/p-reels-pip/steps/02-transcribe.md",
    "skills/p-reels-pip-heygen/steps/02-transcribe.md",
    "skills/p-reels-spotlight/SKILL.md",
    "skills/p-reels-spotlight/steps/02-transcribe.md",
    "skills/p-reels-spotlight-heygen/steps/02-transcribe.md",
]

try:
    bad_hits = []
    for rel in EDITED:
        text = (repo / rel).read_text(encoding="utf-8")
        if BAD_RE.search(text):
            bad_hits.append(rel)
        if GOOD not in text:
            bad_hits.append("%s missing good id" % rel)
        sys.stderr.write("WI2.68-HASH %s %s\n" % (rel, sha256_file(repo / rel)))
    for recipe in ("p-reels-pip", "p-reels-spotlight", "p-reels-pip-heygen", "p-reels-spotlight-heygen"):
        sys.stderr.write("WI2.68-CHECKSUM %s %s\n" % (recipe, recipe_checksum(recipe)))
    sys.stderr.flush()
    if bad_hits:
        add("WI2.68 edited reel files name whisper-small-mlx", "; ".join(bad_hits))
    else:
        add("WI2.68 edited reel files name whisper-small-mlx")

    idx = json.loads((repo / "skills/index.json").read_text(encoding="utf-8"))
    hash_mismatches = []
    checksum_mismatches = []
    for rel in EDITED:
        parts = Path(rel).parts  # skills, recipe, ...
        recipe = parts[1]
        file_rel = "/".join(parts[2:])
        actual = sha256_file(repo / rel)
        expected = (idx.get("recipes", {}).get(recipe, {}).get("fileHashes") or {}).get(file_rel)
        if expected != actual:
            hash_mismatches.append("%s/%s expected %s actual %s" % (recipe, file_rel, expected, actual))
    for recipe in ("p-reels-pip", "p-reels-spotlight", "p-reels-pip-heygen", "p-reels-spotlight-heygen"):
        actual_cs = recipe_checksum(recipe)
        expected_cs = (idx.get("recipes", {}).get(recipe) or {}).get("checksum")
        if expected_cs != actual_cs:
            checksum_mismatches.append("%s expected %s actual %s" % (recipe, expected_cs, actual_cs))
    if hash_mismatches:
        add("WI2.68 index.json fileHashes match edited reel files", "; ".join(hash_mismatches))
    else:
        add("WI2.68 index.json fileHashes match edited reel files")
    if checksum_mismatches:
        add("WI2.68 index.json recipe checksums match", "; ".join(checksum_mismatches))
    else:
        add("WI2.68 index.json recipe checksums match")

    spec = importlib.util.spec_from_file_location("sync_skills_wi268", repo / "scripts/sync-skills.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    sample_bad = 'mlx_whisper x --model mlx-community/whisper-small --output-dir w\n'
    sample_good = 'mlx_whisper x --model mlx-community/whisper-small-mlx --output-dir w\n'
    once = mod.rewrite_whisper_small_mlx(sample_bad)
    twice = mod.rewrite_whisper_small_mlx(once)
    already = mod.rewrite_whisper_small_mlx(sample_good)
    if once != sample_good:
        add("WI2.68 rewrite_whisper_small_mlx rewrites the bad id", repr(once))
    elif twice != sample_good:
        add("WI2.68 rewrite_whisper_small_mlx rewrites the bad id", "second pass changed text")
    elif already != sample_good:
        add("WI2.68 rewrite_whisper_small_mlx rewrites the bad id", "good id was altered")
    else:
        add("WI2.68 rewrite_whisper_small_mlx rewrites the bad id")

    with tempfile.TemporaryDirectory(prefix="wi268-tx-") as tmp:
        root = Path(tmp)
        recipe = root / "recipe"
        (recipe / "steps").mkdir(parents=True)
        hub = recipe / ".hub" / "p-reels-split" / "steps"
        hub.mkdir(parents=True)
        (recipe / "SKILL.md").write_text(
            "# demo\nmlx_whisper a --model mlx-community/whisper-small --out x\n",
            encoding="utf-8",
        )
        (recipe / "steps" / "02-transcribe.md").write_text(
            "mlx_whisper b --model mlx-community/whisper-small --out y\n",
            encoding="utf-8",
        )
        (hub / "02-transcribe.md").write_text(
            "mlx_whisper c --model mlx-community/whisper-small --out z\n",
            encoding="utf-8",
        )
        n1 = mod.apply_whisper_small_mlx(recipe)
        texts = [
            (recipe / "SKILL.md").read_text(encoding="utf-8"),
            (recipe / "steps" / "02-transcribe.md").read_text(encoding="utf-8"),
            (hub / "02-transcribe.md").read_text(encoding="utf-8"),
        ]
        n2 = mod.apply_whisper_small_mlx(recipe)
        again = [
            (recipe / "SKILL.md").read_text(encoding="utf-8"),
            (recipe / "steps" / "02-transcribe.md").read_text(encoding="utf-8"),
            (hub / "02-transcribe.md").read_text(encoding="utf-8"),
        ]
        detail = ""
        if n1 != 3:
            detail = "first apply changed %d files" % n1
        elif any(BAD_RE.search(t) for t in texts) or any(GOOD not in t for t in texts):
            detail = "first apply left a bad or missing good id"
        elif n2 != 0:
            detail = "second apply changed %d files" % n2
        elif again != texts:
            detail = "second apply mutated bytes"
        if detail:
            add("WI2.68 apply_whisper_small_mlx is idempotent and covers hub copies", detail)
        else:
            add("WI2.68 apply_whisper_small_mlx is idempotent and covers hub copies")

        src = root / "src"
        for name, deps, body in (
            ("p-reels-pip", "[]", sample_bad),
            ("p-reels-faceless", "[]", sample_bad),
            ("p-reels-pip-heygen", "[p-reels-pip]", sample_bad),
        ):
            steps = src / name / "steps"
            steps.mkdir(parents=True)
            (src / name / "SKILL.md").write_text(
                "---\nname: %s\ndependsOn: %s\n---\n# %s\n%s" % (name, deps, name, body),
                encoding="utf-8",
            )
            (steps / "02-transcribe.md").write_text(body, encoding="utf-8")
        recipes = root / "recipes.json"
        recipes.write_text(json.dumps({
            "source": "test-wi268",
            "recipes": [
                {"name": "p-reels-pip", "version": "1.0.0", "providers": []},
                {"name": "p-reels-faceless", "version": "1.0.0", "providers": []},
                {"name": "p-reels-pip-heygen", "version": "1.0.0", "providers": []},
            ],
        }), encoding="utf-8")
        out = root / "out"
        env = os.environ.copy()
        env["CFW_SKILLS_SRC"] = str(src)
        proc = subprocess.run(
            ["bash", str(repo / "scripts/sync-skills.sh"), "--recipes", str(recipes),
             "--out-dir", str(out), "--skip-manifest"],
            capture_output=True, text=True, env=env,
        )
        paths = [
            out / "p-reels-pip/SKILL.md",
            out / "p-reels-pip/steps/02-transcribe.md",
            out / "p-reels-faceless/SKILL.md",
            out / "p-reels-faceless/steps/02-transcribe.md",
            out / "p-reels-pip-heygen/steps/02-transcribe.md",
            out / "p-reels-pip-heygen/.hub/p-reels-pip/steps/02-transcribe.md",
        ]
        bad_sync = []
        if proc.returncode != 0:
            bad_sync.append("rc %s %s" % (proc.returncode, (proc.stderr or proc.stdout or "")[-400:]))
        for path in paths:
            if not path.is_file():
                bad_sync.append("missing %s" % path.relative_to(out))
                continue
            text = path.read_text(encoding="utf-8")
            if BAD_RE.search(text):
                bad_sync.append("bad id in %s" % path.relative_to(out))
            if GOOD not in text:
                bad_sync.append("no good id in %s" % path.relative_to(out))
        # Idempotent second sync on already-good output: re-copy from a good src
        # is covered by apply on the out tree directly.
        n_again = mod.apply_whisper_small_mlx(out / "p-reels-pip")
        if n_again != 0:
            bad_sync.append("re-apply on synced pip changed %d" % n_again)
        if bad_sync:
            add("WI2.68 sync-skills.sh rewrites whisper-small on reel recipes and hub copies", "; ".join(bad_sync))
        else:
            add("WI2.68 sync-skills.sh rewrites whisper-small on reel recipes and hub copies")
except Exception as exc:
    add("WI2.68 whisper model harness", "%s: %s" % (type(exc).__name__, exc))

for name, detail in rows:
    if detail:
        print("BAD\t%s\t%s" % (name, detail))
    else:
        print("OK\t%s\t." % (name,))
PY
)" || wi268_rc=$?
if [[ "$wi268_rc" != "0" ]]; then
  fail "WI2.68 whisper model harness" "python exited $wi268_rc"
fi
while IFS=$'\t' read -r status name detail; do
  [[ -z "${status:-}" ]] && continue
  if [[ "$status" == "OK" ]]; then
    pass "$name"
  else
    fail "$name" "$detail"
  fi
done <<EOF
$wi268_out
EOF

echo "=== Case 47: WI2.66 — a reel missing final_video or cover fails the attempt ==="
# A reel whose delivery list has no final_video, or no cover, used to report
# attempt_completed with no media. The worker then blocked. The attempt must
# fail and the reason must name the missing file. A reel with both still
# completes, and step videos stay out of that list.
wi266_run() {
  local slug="$1" mode="$2" root rc=0 detail=""
  root="$(mktemp -d)"
  python3 - "$root/order.json" "$slug" "$mode" <<'PY'
import json, sys
dest, slug, mode = sys.argv[1:]
saves = [{"id": "voice_track", "kind": "video"}]
if mode != "missing-video":
    saves.append({"id": "final_video", "kind": "video"})
if mode != "missing-cover":
    saves.append({"id": "cover", "kind": "image"})
saves.append({"id": "captions", "kind": "json"})
json.dump({
    "id": "order-wi266",
    "attempt": {"id": "att-wi266"},
    "recipe": slug,
    "kind": "video",
    "taskOrder": {},
    "inputs": {},
    "manifest": {
        "recipe": slug,
        "recipeVersion": "2026.10.2",
        "steps": [{
            "id": "render",
            "runsOn": "computer",
            "when": "always",
            "saves": saves,
        }],
    },
}, open(dest, "w"))
PY
  python3 - "$root/engine.sh" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text("""#!/usr/bin/env bash
set -eu
cat >/dev/null
mkdir -p saves
for sv in ${CFW_STEP_SAVES:-}; do
  sid="${sv%%:*}"
  ext="${sv##*:}"
  printf '%s\\n' "${sid}-bytes" > "saves/${sid}.${ext}"
done
""")
PY
  chmod +x "$root/engine.sh"
  (
    export CFW_RENDER_LOG_DIR="$root/logs"
    export CFW_RENDER_STATE_DIR="$root/state"
    export CFW_RENDER_ENGINE=codex
    export CFW_RENDER_ENGINE_CMD="$root/engine.sh"
    export CFW_WORKER_ID="w-wi266"
    export CFW_ORDER_ID="order-wi266"
    export CFW_API_BASE="http://127.0.0.1:9"
    export CFW_RENDER_WORKER_KEY="cfw_render_wi266testkey0000"
    export CFW_RENDER_HEARTBEAT_SEC=30
    export CFW_RENDER_STEP_TIMEOUT_SEC=60
    export WI266_REPORTS="$root/reports.ndjson"
    unset CFW_RENDER_SKILLS_DIR
    unset CFW_RENDER_LOCAL_CHECKPOINTS
    mkdir -p "$root/logs" "$root/state"
    # shellcheck disable=SC1091
    source "$REPO_DIR/bin/cfw-render-lib.sh"
    source "$REPO_DIR/bin/cfw-render-engine.sh"
    source "$REPO_DIR/bin/cfw-render-harness.sh"
    cr_harness_heartbeat_start() { :; }
    cr_harness_heartbeat_stop() { :; }
    cr_h_run_with_timeout() { shift; "$@"; }
    cr_engine_limit_detect() { return 1; }
    cr_h_upload_with_retry() { printf 'https://media.cfw.social/%s' "$(basename "$1")"; }
    cr_report_step() {
      python3 -c 'import json,sys
open(sys.argv[1], "a").write(json.dumps({"event": sys.argv[2], "extra": json.loads(sys.argv[3])}) + "\n")' \
        "$WI266_REPORTS" "$5" "$6" || return 1
      printf '%s' '{"ok":true,"directive":"continue"}'
    }
    cr_harness_run "$root/order.json" "$root" "$root/recipe" >"$root/harness.out" 2>"$root/harness.err"
  )
  rc=$?
  printf '%s\n' "$rc" > "$root/rc"
  detail="$(python3 - "$root" "$mode" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
rc = (root / "rc").read_text(encoding="utf-8").strip() if (root / "rc").is_file() else ""
err = ""
err_path = root / "harness.err"
if err_path.is_file():
    err = err_path.read_text(errors="replace")[-500:].replace("\n", " | ")
events = []
reports = root / "reports.ndjson"
if reports.is_file():
    for line in reports.read_text(encoding="utf-8").splitlines():
        if line.strip():
            events.append(json.loads(line))
names = [e.get("event") for e in events]
failed = [e for e in events if e.get("event") == "attempt_failed"]
completed = [e for e in events if e.get("event") == "attempt_completed"]
bad = []
if mode == "complete":
    if rc != "0":
        bad.append("rc=%s err=%s" % (rc, err))
    if names[-1:] != ["attempt_completed"]:
        bad.append("events=%s err=%s" % (names, err))
    if failed:
        bad.append("attempt_failed=%r" % failed)
    try:
        items = json.loads((root / "harness.out").read_text(encoding="utf-8"))
    except Exception as exc:
        bad.append("stdout %s" % exc)
        items = None
    if isinstance(items, list):
        ids = [i.get("id") for i in items if isinstance(i, dict)]
        if ids != ["final_video", "cover", "captions"]:
            bad.append("ids=%r" % ids)
        if "voice_track" in json.dumps(items):
            bad.append("leaked voice_track")
else:
    want = "final_video" if mode == "missing-video" else "cover"
    if rc != "30":
        bad.append("rc=%s err=%s events=%s" % (rc, err, names))
    if "attempt_completed" in names:
        bad.append("attempt_completed events=%s" % names)
    if len(failed) != 1:
        bad.append("attempt_failed count=%d events=%s err=%s" % (len(failed), names, err))
    else:
        msg = (failed[0].get("extra") or {}).get("message") or ""
        if msg != want + " is missing":
            bad.append("message=%r" % msg)
print("ok" if not bad else "; ".join(bad))
PY
)"
  rm -rf "$root"
  printf '%s\n' "$detail"
}

for wi266_slug in p-reels-spotlight p-reels-pip; do
  wi266_detail="$(wi266_run "$wi266_slug" missing-video)"
  if [[ "$wi266_detail" == "ok" ]]; then
    pass "WI2.66 $wi266_slug missing final_video reports attempt_failed, not attempt_completed"
  else
    fail "WI2.66 $wi266_slug missing final_video" "$wi266_detail"
  fi
  wi266_detail="$(wi266_run "$wi266_slug" missing-cover)"
  if [[ "$wi266_detail" == "ok" ]]; then
    pass "WI2.66 $wi266_slug missing cover reports attempt_failed, not attempt_completed"
  else
    fail "WI2.66 $wi266_slug missing cover" "$wi266_detail"
  fi
  wi266_detail="$(wi266_run "$wi266_slug" complete)"
  if [[ "$wi266_detail" == "ok" ]]; then
    pass "WI2.66 $wi266_slug with final_video and cover reports attempt_completed"
  else
    fail "WI2.66 $wi266_slug complete reel" "$wi266_detail"
  fi
done

echo "=== Case 48: WI2.70 — a failed check on run 1 names itself in the step event and the worker log ==="
# Run 1 fails picture_review; run 2 passes. The retry count stays one failure
# then success. The check name and its short message are on the step event
# detail and on the worker log. A planted secret and a save-file body are not.
wi270_root="$(mktemp -d)"
python3 - "$wi270_root" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
(root / "recipe" / "checks").mkdir(parents=True)
(root / "recipe" / "checks" / "picture_review.sh").write_text("""#!/bin/bash
nfile="$1/.wi270-runs"
n=0
if [[ -f "$nfile" ]]; then n=$(cat "$nfile"); fi
n=$((n + 1))
printf '%s' "$n" > "$nfile"
if [[ "$n" -eq 1 ]]; then
  printf '%s\\n' "black last frame sk-wi270secretvalue0001"
  exit 1
fi
exit 0
""")
order = {
    "id": "order-wi270",
    "attempt": {"id": "att-wi270"},
    "recipe": "wi270-check",
    "kind": "video",
    "taskOrder": {},
    "inputs": {},
    "manifest": {
        "recipe": "wi270-check",
        "recipeVersion": "1.0.0",
        "steps": [{
            "id": "final_checks",
            "runsOn": "computer",
            "when": "always",
            "maxCheckRetries": 1,
            "saves": [{"id": "note", "kind": "text"}],
            "checks": [{"id": "picture_review"}],
        }],
    },
}
(root / "order.json").write_text(__import__("json").dumps(order))
(root / "engine.sh").write_text("""#!/bin/bash
set -eu
cat >/dev/null
mkdir -p saves
printf '%s\\n' "FILEBODY-wi270-do-not-copy" > saves/note.md
""")
PY
chmod +x "$wi270_root/engine.sh"
(
  export CFW_RENDER_LOG_DIR="$wi270_root/logs"
  export CFW_RENDER_STATE_DIR="$wi270_root/state"
  export CFW_RENDER_ENGINE=codex
  export CFW_RENDER_ENGINE_CMD="$wi270_root/engine.sh"
  export CFW_WORKER_ID="w-wi270"
  export CFW_ORDER_ID="order-wi270"
  export CFW_API_BASE="http://127.0.0.1:9"
  export CFW_RENDER_WORKER_KEY="cfw_render_wi270testkey0000"
  export CFW_RENDER_HEARTBEAT_SEC=30
  export CFW_RENDER_STEP_TIMEOUT_SEC=60
  export WI270_REPORTS="$wi270_root/reports.ndjson"
  unset CFW_RENDER_SKILLS_DIR
  unset CFW_RENDER_LOCAL_CHECKPOINTS
  mkdir -p "$wi270_root/logs" "$wi270_root/state"
  # shellcheck disable=SC1091
  source "$REPO_DIR/bin/cfw-render-lib.sh"
  source "$REPO_DIR/bin/cfw-render-engine.sh"
  source "$REPO_DIR/bin/cfw-render-harness.sh"
  cr_harness_heartbeat_start() { :; }
  cr_harness_heartbeat_stop() { :; }
  cr_h_run_with_timeout() { shift; "$@"; }
  cr_engine_limit_detect() { return 1; }
  cr_h_upload_with_retry() { printf 'https://media.cfw.social/%s' "$(basename "$1")"; }
  cr_report_step() {
    python3 -c 'import json,sys
open(sys.argv[1], "a").write(json.dumps({"event": sys.argv[2], "extra": json.loads(sys.argv[3])}) + "\n")' \
      "$WI270_REPORTS" "$5" "$6" || return 1
    printf '%s' '{"ok":true,"directive":"continue"}'
  }
  cr_harness_run "$wi270_root/order.json" "$wi270_root" "$wi270_root/recipe" >"$wi270_root/harness.out" 2>"$wi270_root/harness.err"
)
wi270_rc=$?
wi270_detail="$(python3 - "$wi270_root" "$wi270_rc" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
rc = sys.argv[2]
bad = []
err = ""
err_path = root / "harness.err"
if err_path.is_file():
    err = err_path.read_text(errors="replace")[-500:].replace("\n", " | ")
if rc != "0":
    bad.append("rc=%s err=%s" % (rc, err))
events = []
reports = root / "reports.ndjson"
if reports.is_file():
    for line in reports.read_text(encoding="utf-8").splitlines():
        if line.strip():
            events.append(json.loads(line))
names = [e.get("event") for e in events]
started = [e for e in events if e.get("event") == "step_started"]
completed = [e for e in events if e.get("event") == "step_completed"]
if names != ["step_started", "step_started", "step_completed", "attempt_completed"]:
    bad.append("events=%s err=%s" % (names, err))
if any(e.get("event") == "attempt_failed" for e in events):
    bad.append("attempt_failed")
log_path = root / "logs" / "cfw-render.log"
log = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
want = "picture_review: black last frame sk-[redacted]"
if log.count("checks failed") != 1 or "run 1/2" not in log or want not in log or "retrying" not in log:
    bad.append("log=%r" % log[-500:])
details = []
if len(started) >= 2:
    details.append((started[1].get("extra") or {}).get("detail") or "")
if completed:
    details.append((completed[0].get("extra") or {}).get("detail") or "")
if not details or any(want not in d for d in details):
    bad.append("detail=%r" % details)
blob = log + "\n" + (reports.read_text(encoding="utf-8") if reports.is_file() else "")
if "sk-wi270secretvalue0001" in blob or "FILEBODY-wi270-do-not-copy" in blob:
    bad.append("leaked secret or file body")
runs = root / "steps" / "final_checks" / ".wi270-runs"
got_runs = runs.read_text(encoding="utf-8") if runs.is_file() else ""
if got_runs != "2":
    bad.append("runs=%r" % got_runs)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi270_detail" == "ok" ]]; then
  pass "WI2.70 failed check on run 1 is named in the step event detail and the worker log; run 2 completes"
else
  fail "WI2.70 check failure detail" "$wi270_detail"
fi
rm -rf "$wi270_root"

echo "=== Case 49: WI2.71 — reel face clip fills the spotlight frame and the pip card (no pad bars) ==="
# The owner's HeyGen clip is 1080x1920 with a 16:9 picture between flat light bars.
# For wide, tall, light-barred and mint-barred clips, the bar helper and fill
# filters taken from the step docs must leave no flat bar on any edge.
wi271_root="$(mktemp -d)"
wi271_detail="$(python3 - "$REPO_DIR" "$wi271_root" <<'PY'
import importlib.util, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
def ff(*a):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *a], check=True)
def frame(src, vf, w, h):
    out = subprocess.run(["ffmpeg", "-v", "error", "-i", str(src), "-frames:v", "1", "-vf", vf,
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
    if len(out) != w * h * 3:
        raise RuntimeError("frame size %d != %dx%d" % (len(out), w, h))
    return out
def flat(fr, w, pts):
    ref = None
    for x, y in pts:
        i = (y * w + x) * 3; c = fr[i:i + 3]; ref = ref or c
        if max(abs(c[k] - ref[k]) for k in range(3)) > 12:
            return False
    return True
def edges(fr, w, h):
    sides = {"top": [(x, 1) for x in range(w)], "bottom": [(x, h - 2) for x in range(w)],
             "left": [(1, y) for y in range(h)], "right": [(w - 2, y) for y in range(h)]}
    return [k for k, pts in sides.items() if flat(fr, w, pts)]
try:
    clips = {}
    # noise gives every picture row and column texture; the pad bars stay flat.
    for name, src, vf in (("wide", "testsrc2=s=1920x1080:d=1:r=5", "noise=alls=60:allf=t"),
                          ("tall", "testsrc2=s=1080x1920:d=1:r=5", "noise=alls=60:allf=t"),
                          ("light", "testsrc2=s=1080x608:d=1:r=5", "noise=alls=60:allf=t,pad=1080:1920:0:656:color=0xF4F6FA"),
                          ("mint", "testsrc2=s=1080x608:d=1:r=5", "noise=alls=60:allf=t,pad=1080:1920:0:656:color=0x9FE2BF")):
        clips[name] = root / (name + ".mp4")
        ff("-f", "lavfi", "-i", src, "-vf", vf, "-pix_fmt", "yuv420p", str(clips[name]))
    docs = {r: (repo / "skills" / r / "steps" / "01-prepare-footage.md").read_text(encoding="utf-8")
            for r in ("p-reels-spotlight", "p-reels-spotlight-heygen", "p-reels-pip", "p-reels-pip-heygen")}
    helpers = set()
    for r, text in docs.items():
        m = re.search(r"cat > work/bars\.py <<'PY'\n(.*?\n)PY\n", text, re.S)
        if not m:
            bad.append("%s: no bars.py helper" % r); continue
        helpers.add(m.group(1))
    if len(helpers) != 1:
        bad.append("bars.py helpers differ across recipes: %d" % len(helpers))
    helper = root / "bars.py"; helper.write_text(sorted(helpers)[0] if helpers else "", encoding="utf-8")
    m = re.search(r'-vf "(\$\{CROP\}scale=1080:1920:[^"]*)"', docs["p-reels-spotlight"])
    spot_vf = m.group(1) if m else ""
    if "increase,crop=1080:1920" not in spot_vf:
        bad.append("spotlight bed vf is not fill+crop: %r" % spot_vf)
    comp = {r: (repo / "skills" / r / "steps" / "05-composite.md").read_text(encoding="utf-8")
            for r in ("p-reels-pip", "p-reels-pip-heygen")}
    card = []
    for r, text in comp.items():
        heads = re.findall(r'FC="\[1:v\](scale=\$\{CARD_W\}[^\[]*)\[thfit\]', text)
        if len(heads) != 3 or any("pad=" in h or "decrease" in h or "increase,crop=${CARD_W}:${CARD_H}" not in h for h in heads):
            bad.append("%s card filters not fill+crop: %r" % (r, heads))
        card += heads
    card_vf = (card[-1] if card else "").replace("${CARD_W}", "364").replace("${CARD_H}", "504")
    for name, clip in clips.items():
        crop = subprocess.run([sys.executable, "-I", str(helper), str(clip)], capture_output=True, text=True, check=True).stdout.strip()
        if name in ("light", "mint") and not crop.startswith("crop="):
            bad.append("%s: bars not found" % name)
        if name in ("wide", "tall") and crop:
            bad.append("%s: false bar crop %r" % (name, crop))
        fr = frame(clip, spot_vf.replace("${CROP}", crop), 1080, 1920)
        e = edges(fr, 1080, 1920)
        if e:
            bad.append("%s spotlight flat edges %s (crop %r)" % (name, e, crop))
        bed = root / ("bed-" + name + ".mp4")
        ff("-i", str(clip), "-vf", crop + "fps=30,setsar=1,format=yuv420p", str(bed))
        fr = frame(bed, card_vf, 364, 504)
        e = edges(fr, 364, 504)
        if e:
            bad.append("%s pip card flat edges %s (crop %r)" % (name, e, crop))
    spec = importlib.util.spec_from_file_location("wi271_sync", repo / "scripts" / "sync-skills.py")
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    for r in docs:
        tmp = root / "sync" / r; shutil.copytree(repo / "skills" / r / "steps", tmp / "steps")
        if mod.apply_reel_fill_frame(tmp, r) != 0:
            bad.append("%s: sync transform not idempotent" % r)
except Exception as exc:
    bad.append("error: %s" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi271_detail" == "ok" ]]; then
  pass "WI2.71 spotlight frame and pip card are filled for wide, tall and barred clips"
else
  fail "WI2.71 reel fill frame" "$wi271_detail"
fi
rm -rf "$wi271_root"

echo "=== Case 50: WI2.71 rework — crop only a matched bar pair, keep the face, top-biased pip card ==="
# Review of the first WI2.71 commit: a speaker on a plain backdrop lost the head
# (every flat edge was cropped on its own), the pip card centre-cropped the top,
# rotated clips were read on the coded axes, and the crop was not even. The
# helper and filters taken from the step docs and SKILL.md must now crop only a
# matched pair, never a plain backdrop, and keep the top of the picture.
wi271b_root="$(mktemp -d)"
wi271b_detail="$(python3 - "$REPO_DIR" "$wi271b_root" <<'PY'
import importlib.util, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
RECIPES = ("p-reels-spotlight", "p-reels-spotlight-heygen", "p-reels-pip", "p-reels-pip-heygen")
def ff(*a):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *a], check=True)
def frame(src, vf, w, h):
    out = subprocess.run(["ffmpeg", "-v", "error", "-i", str(src), "-frames:v", "1", "-vf", vf,
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
    if len(out) != w * h * 3:
        raise RuntimeError("frame size %d != %dx%d" % (len(out), w, h))
    return out
def first_busy_row(fr, w, h):
    # first row from the top that is not one flat colour (the subject's top edge)
    for y in range(h):
        row = [fr[(y * w + x) * 3:(y * w + x) * 3 + 3] for x in range(0, w, 2)]
        if any(max(abs(c[k] - row[0][k]) for k in range(3)) > 12 for c in row):
            return y
    return h
try:
    steps = {r: (repo / "skills" / r / "steps" / "01-prepare-footage.md").read_text(encoding="utf-8") for r in RECIPES}
    helpers = {re.search(r"cat > work/bars\.py <<'PY'\n(.*?\n)PY\n", t, re.S).group(1) for t in steps.values()}
    for r in ("p-reels-spotlight", "p-reels-pip"):
        m = re.search(r"cat > \"\$W/bars\.py\" <<'PY'\n(.*?\n)PY\n", (repo / "skills" / r / "SKILL.md").read_text(encoding="utf-8"), re.S)
        if not m:
            bad.append("%s SKILL.md: no bars.py helper in Step 1.5" % r)
        else:
            helpers.add(m.group(1))
    if len(helpers) != 1:
        bad.append("bars.py helpers differ across steps/SKILL.md: %d" % len(helpers))
    helper = root / "bars.py"; helper.write_text(sorted(helpers)[0], encoding="utf-8")
    spot_vf = re.search(r'-vf "(\$\{CROP\}scale=1080:1920:[^"]*)"', steps["p-reels-spotlight"]).group(1)
    comp = (repo / "skills" / "p-reels-pip" / "steps" / "05-composite.md").read_text(encoding="utf-8")
    heads = re.findall(r'FC="\[1:v\](scale=\$\{CARD_W\}[^\[]*)\[thfit\]', comp)
    skill_heads = re.findall(r'FC="\[1:v\](scale=\$\{CARD_W\}[^\[]*)\[thfit\]',
                             (repo / "skills" / "p-reels-pip" / "SKILL.md").read_text(encoding="utf-8"))
    for name, hs in (("05-composite", heads), ("SKILL.md", skill_heads)):
        if len(hs) != 3 or any("crop=${CARD_W}:${CARD_H}:(iw-ow)/2:0" not in h or "pad=" in h for h in hs):
            bad.append("p-reels-pip %s card crop not top-biased fill: %r" % (name, hs))
    card_vf = heads[-1].replace("${CARD_W}", "364").replace("${CARD_H}", "504")
    subj = "testsrc2=s=%s:d=1:r=5,noise=alls=60:allf=t"
    clips = {
        # speaker on a plain backdrop, margins on every side: must NOT be cropped
        "solid": ("color=c=0x2E7D32:s=1080x1920:d=1:r=5", subj % "520x1400", "overlay=280:260", "", 260),
        # dark backdrop, body runs off the bottom: must NOT be cropped
        "dark": ("color=c=black:s=1080x1920:d=1:r=5", subj % "600x1700", "overlay=240:220", "", 220),
        # 16:9 picture between unequal bars (400 / 912): not a matched pair, no crop
        "unequal": ("color=c=0xF4F6FA:s=1080x1920:d=1:r=5", subj % "1080x608", "overlay=0:400", "", None),
        # 9:16 picture between two side bars: a matched left+right pair
        "pillar": ("color=c=0xF4F6FA:s=1920x1080:d=1:r=5", subj % "608x1080", "overlay=656:0", "crop=608:1080:656:0,", None),
        # odd bars (655 / 657, lossless so the edge is exact): crop x/y/w/h all even, no bar row kept
        "odd": ("color=c=0x9FE2BF:s=1080x1920:d=1:r=5", subj % "1080x608", "overlay=0:655", "crop=1080:606:0:656,", None),
    }
    for name, (bg, fg, ov, want, subj_top) in clips.items():
        # the odd clip is lossless RGB (ffv1) so its bar edge lands on exactly row 655
        lossless = name == "odd"
        clip = root / (name + (".mkv" if lossless else ".mp4"))
        fc = "[0:v][1:v]" + ov + (":format=rgb,format=rgb24" if lossless else ",format=yuv420p")
        ff("-f", "lavfi", "-i", bg, "-f", "lavfi", "-i", fg, "-filter_complex", fc, "-frames:v", "5",
           *(("-c:v", "ffv1") if lossless else ()), str(clip))
        crop = subprocess.run([sys.executable, "-I", str(helper), str(clip)], capture_output=True, text=True, check=True).stdout.strip()
        if crop != want:
            bad.append("%s: crop %r, want %r" % (name, crop, want)); continue
        if crop and any(int(v) % 2 for v in crop[5:-1].split(":")):
            bad.append("%s: crop not even %r" % (name, crop))
        if subj_top is None:
            continue
        src_top = first_busy_row(frame(clip, "null", 1080, 1920), 1080, 1920)
        spot_top = first_busy_row(frame(clip, spot_vf.replace("${CROP}", crop), 1080, 1920), 1080, 1920)
        if abs(spot_top - src_top) > 2 or abs(src_top - subj_top) > 6:
            bad.append("%s spotlight: subject top %d moved to %d (source %d)" % (name, subj_top, spot_top, src_top))
        bed = root / ("bed-" + name + ".mp4")
        ff("-i", str(clip), "-vf", crop + "fps=30,setsar=1,format=yuv420p", str(bed))
        card_top = first_busy_row(frame(bed, card_vf, 364, 504), 364, 504)
        want_top = subj_top * 364 / 1080
        if not 1 <= card_top or abs(card_top - want_top) > 4:
            bad.append("%s pip card: subject top at %d, want ~%.0f (top cut?)" % (name, card_top, want_top))
    # rotated phone clip: stored 1920x1080 with a 90-degree display tag, shown 1080x1920 with bars
    raw, rot = root / "rot-raw.mp4", root / "rot.mp4"
    ff("-f", "lavfi", "-i", "testsrc2=s=1080x608:d=1:r=5",
       "-vf", "noise=alls=60:allf=t,pad=1080:1920:0:656:color=0xF4F6FA,transpose=1", "-pix_fmt", "yuv420p", str(raw))
    ff("-display_rotation:v:0", "90", "-i", str(raw), "-c", "copy", str(rot))
    crop = subprocess.run([sys.executable, "-I", str(helper), str(rot)], capture_output=True, text=True, check=True).stdout.strip()
    if crop != "crop=1080:608:0:656,":
        bad.append("rotated: crop %r, want display-axis crop=1080:608:0:656," % crop)
    # sync transform: pair replacement is specific to each pair and idempotent
    spec = importlib.util.spec_from_file_location("wi271b_sync", repo / "scripts" / "sync-skills.py")
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    t = mod._apply_pairs("NEW here\nOLD there\n", (("OLD", "NEW"),))
    if t != "NEW here\nNEW there\n":
        bad.append("_apply_pairs skipped a pair whose new text was elsewhere: %r" % t)
    t1 = mod._apply_pairs("a fit b", (("fit", "fit + crop"),))
    if t1 != "a fit + crop b" or mod._apply_pairs(t1, (("fit", "fit + crop"),)) != t1:
        bad.append("_apply_pairs not idempotent when new contains old: %r" % t1)
    for r in RECIPES:
        tmp = root / "sync" / r; shutil.copytree(repo / "skills" / r / "steps", tmp / "steps")
        shutil.copy(repo / "skills" / r / "SKILL.md", tmp / "SKILL.md")
        if mod.apply_reel_fill_frame(tmp, r) != 0:
            bad.append("%s: sync transform not idempotent on SKILL.md/steps" % r)
except Exception as exc:
    bad.append("error: %s" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi271b_detail" == "ok" ]]; then
  pass "WI2.71 rework crops only matched bar pairs, keeps the face and top-biases the pip card"
else
  fail "WI2.71 rework matched bar pairs" "$wi271b_detail"
fi
rm -rf "$wi271b_root"

echo "=== Case 51: WI2.75 — a thin flat seam next to a reel bar is trimmed (7+ rows is kept) ==="
# Review of WI2.71: the owner's clip has a 4-row mid-grey seam between the face picture and
# the bottom bar. bars.py stopped at the seam and the grey line showed as a band. A flat run
# of 6 rows or fewer beside a bar now counts as bar; 7 rows or more is picture. Also: the
# sync transform must fail fast (non-zero) when its anchor text is missing.
wi275_root="$(mktemp -d)"
wi275_detail="$(python3 - "$REPO_DIR" "$wi275_root" <<'PY'
import re, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
RECIPES = ("p-reels-spotlight", "p-reels-spotlight-heygen", "p-reels-pip", "p-reels-pip-heygen")
def ff(*a):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *a], check=True)
try:
    helpers = {re.search(r"cat > work/bars\.py <<'PY'\n(.*?\n)PY\n",
               (repo / "skills" / r / "steps" / "01-prepare-footage.md").read_text(encoding="utf-8"), re.S).group(1) for r in RECIPES}
    for r in ("p-reels-spotlight", "p-reels-pip"):
        helpers.add(re.search(r"cat > \"\$W/bars\.py\" <<'PY'\n(.*?\n)PY\n",
                    (repo / "skills" / r / "SKILL.md").read_text(encoding="utf-8"), re.S).group(1))
    if len(helpers) != 1:
        bad.append("bars.py helpers differ across recipes: %d" % len(helpers))
    helper = root / "bars.py"; helper.write_text(sorted(helpers)[0], encoding="utf-8")
    def clip(name, pic_h, seam_h, seam_top=False):
        # 1080x1920 lossless: top bar 656 rows, picture, grey seam, bottom bar
        out = root / (name + ".mkv")
        seam_y = 656 + pic_h
        # the seam is mid-grey with +-12 of speckle, like the owner's compressed clip
        # planar RGB so an odd overlay row is exact (yuv420 would round it to even)
        fc = ("[0:v]format=gbrp[b];[1:v]format=gbrp[p];[2:v]format=gbrp[s];"
              "[b][p]overlay=0:656[a];[a][s]overlay=0:%d,format=rgb24" % seam_y)
        ff("-f", "lavfi", "-i", "color=c=0xF4F6FA:s=1080x1920:d=1:r=5",
           "-f", "lavfi", "-i", "testsrc2=s=1080x%d:d=1:r=5,noise=alls=60:allf=t" % pic_h,
           "-f", "lavfi", "-i", "color=c=0x727272:s=1080x%d:d=1:r=5,noise=alls=3:allf=t" % seam_h,
           "-filter_complex", fc, "-frames:v", "5", "-c:v", "ffv1", str(out))
        return out
    def crop_of(c):
        return subprocess.run([sys.executable, "-I", str(helper), str(c)], capture_output=True, text=True, check=True).stdout.strip()
    # 4-row seam (the owner's clip): picture 656..1259, seam 1260..1263 is swallowed
    got = crop_of(clip("seam4", 604, 4))
    if got != "crop=1080:604:0:656,":
        bad.append("4-row seam: crop %r, want crop=1080:604:0:656," % got)
    # 6-row seam is the limit and is still swallowed
    got = crop_of(clip("seam6", 604, 6))
    if got != "crop=1080:604:0:656,":
        bad.append("6-row seam: crop %r, want crop=1080:604:0:656," % got)
    # 7-row band is picture, not seam: kept (crop stops at the bar)
    got = crop_of(clip("band7", 602, 7))
    if got != "crop=1080:608:0:656,":
        bad.append("7-row band: crop %r, want crop=1080:608:0:656," % got)
    # no flat row at the cropped picture's bottom edge for the 4-row seam
    c4 = crop_of(root / "seam4.mkv")
    ch = int(c4[5:-1].split(":")[1]); y0 = int(c4[5:-1].split(":")[3])
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(root / "seam4.mkv"), "-frames:v", "1", "-vf", c4 + "format=rgb24",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
    last = [raw[((ch - 1) * 1080 + x) * 3:((ch - 1) * 1080 + x) * 3 + 3] for x in range(0, 1080, 4)]
    if all(max(abs(c[k] - last[0][k]) for k in range(3)) <= 12 for c in last):
        bad.append("cropped 4-row-seam clip still ends on a flat row")
    # sync transform fails fast when the anchor text is gone
    src = root / "src"; (src / "p-reels-spotlight" / "steps").mkdir(parents=True)
    (src / "p-reels-spotlight" / "steps" / "01-prepare-footage.md").write_text("### 2. Detect something else (BEFORE anything else)\nno matching anchor\n", encoding="utf-8")
    code = ("import importlib.util,sys\nfrom pathlib import Path\n"
            "s=importlib.util.spec_from_file_location('m',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
            "m.apply_reel_fill_frame(Path(sys.argv[2]),'p-reels-spotlight')\n")
    r = subprocess.run([sys.executable, "-I", "-c", code, str(repo / "scripts" / "sync-skills.py"), str(src / "p-reels-spotlight")],
                       capture_output=True, text=True)
    if r.returncode == 0 or "anchor text not found" not in r.stderr:
        bad.append("sync transform did not fail fast on a missing anchor (rc=%d)" % r.returncode)
except Exception as exc:
    bad.append("error: %s" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi275_detail" == "ok" ]]; then
  pass "WI2.75 thin seam beside a reel bar is trimmed, a 7-row band is kept, sync fails fast"
else
  fail "WI2.75 thin seam beside a reel bar" "$wi275_detail"
fi
rm -rf "$wi275_root"

echo "=== Case 52: WI2.72 — a mis-heard caption word is corrected to the script word (timings kept) ==="
# Owner report on WI2.9: captions come from the Whisper transcript and nothing checked those
# words against the script the voice was made from. The transcribe step now writes
# work/script_align.py (shipped by scripts/sync-skills.py), passes the script as the
# mlx_whisper --initial-prompt and fixes mis-heard words to the script words, keeping timings.
# No script (an uploaded clip) leaves the words unchanged.
wi272_root="$(mktemp -d)"
wi272_detail="$(python3 - "$REPO_DIR" "$wi272_root" <<'PY'
import hashlib, importlib.util, json, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
RECIPES = ("p-reels-spotlight", "p-reels-spotlight-heygen", "p-reels-pip", "p-reels-pip-heygen")
OPEN = "cat > work/script_align.py <<'PY'\n"
try:
    spec = importlib.util.spec_from_file_location("ss272", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    helpers = {}
    for r in RECIPES:
        body = (repo / "skills" / r / "steps" / "02-transcribe.md").read_text(encoding="utf-8")
        if OPEN not in body:
            bad.append("%s: transcribe step does not write work/script_align.py" % r); continue
        helpers[r] = body.split(OPEN, 1)[1].split("\nPY\n", 1)[0] + "\n"
        if "--initial-prompt \"$SCRIPT_PROMPT\"" not in body:
            bad.append("%s: mlx_whisper is not given the script as --initial-prompt" % r)
        if body.index(OPEN) > body.index("mlx_whisper prior/voice_track.mp4"):
            bad.append("%s: helper is written after mlx_whisper runs" % r)
        if "python3 work/script_align.py work/words.json" not in body:
            bad.append("%s: transcribe step never runs the script check" % r)
    if set(helpers.values()) != {ss._SCRIPT_ALIGN_PY}:
        bad.append("helper differs across recipes or from sync-skills.py")
    helper = root / "script_align.py"; helper.write_text(ss._SCRIPT_ALIGN_PY, encoding="utf-8")
    heard = [("She", 15.53, 15.64), ("approved", 15.65, 16.21), ("them", 16.21, 16.43), ("with", 16.50, 16.77),
             ("flower", 16.90, 17.30), ("steel", 17.30, 17.66), ("on", 17.66, 17.75), ("her", 17.90, 18.00),
             ("hands,", 18.00, 18.42), ("about", 18.53, 18.90), ("30", 18.90, 19.40), ("minutes", 19.40, 20.03)]
    words = [{"text": t, "start": s, "end": e} for t, s, e in heard]
    def run_in(name, script=None, script_file="script.json"):
        wd = root / name; (wd / "work").mkdir(parents=True)
        if script is not None:
            (wd / "inputs" / "script").mkdir(parents=True)
            body = json.dumps({"text": script}) if script_file.endswith(".json") else script
            (wd / "inputs" / "script" / script_file).write_text(body, encoding="utf-8")
        (wd / "work" / "words.json").write_text(json.dumps(words), encoding="utf-8")
        r = subprocess.run([sys.executable, "-I", str(helper), "work/words.json"], cwd=wd, capture_output=True, text=True)
        if r.returncode != 0:
            bad.append("%s: helper rc=%d %s" % (name, r.returncode, r.stderr.strip()[-300:]))
        p = subprocess.run([sys.executable, "-I", str(helper), "--prompt"], cwd=wd, capture_output=True, text=True)
        return json.loads((wd / "work" / "words.json").read_text()), r.stdout, p.stdout.strip()
    script = "She approved them with flour still on her hands... about thirty minutes a week."
    got, out, prompt = run_in("with_script", script)
    texts = [w["text"] for w in got]
    want = ["She", "approved", "them", "with", "flour", "still", "on", "her", "hands,", "about", "thirty", "minutes"]
    if texts != want:
        bad.append("script case: words %r, want %r" % (texts, want))
    if [(w["start"], w["end"]) for w in got] != [(s, e) for _, s, e in heard]:
        bad.append("script case: timings changed")
    if "FLOWER" in " ".join(texts).upper() or "STEEL" in " ".join(texts).upper():
        bad.append("script case: a mis-heard word survived")
    if prompt != script:
        bad.append("--prompt printed %r, want the script text" % prompt)
    # a .md script (prior-style plain text) works the same way
    got_md, _, _ = run_in("md_script", script, "script.md")
    if [w["text"] for w in got_md] != want:
        bad.append("plain-text script was not used")
    # a recognised word that is not in the script is not burned in
    words.insert(9, {"text": "um", "start": 18.42, "end": 18.50})
    got_um, _, _ = run_in("extra_word", script)
    if [w["text"] for w in got_um] != want:
        bad.append("extra word case: %r" % [w["text"] for w in got_um])
    del words[9]
    # no script: unchanged, and the helper says so
    got0, out0, prompt0 = run_in("no_script")
    if got0 != words:
        bad.append("no-script case changed the words")
    if "no script" not in out0 or prompt0 != "":
        bad.append("no-script case did not say so (%r, prompt %r)" % (out0.strip(), prompt0))
    # a script that is not what was spoken: unchanged
    got_x, out_x, _ = run_in("other_script", "Completely different words about a car dealership opening downtown next spring.")
    if got_x != words:
        bad.append("unrelated-script case changed the words")
    # the sync transform is idempotent on the committed files and fails fast on a drifted anchor
    for r in RECIPES:
        cp = root / "copy" / r; shutil.copytree(repo / "skills" / r / "steps", cp / "steps")
        if ss.apply_reel_script_align(cp, r) != 0:
            bad.append("%s: committed transcribe step is not what sync-skills.py writes" % r)
    drift = root / "drift" / "p-reels-pip"; (drift / "steps").mkdir(parents=True)
    (drift / "steps" / "02-transcribe.md").write_text("### 1. Something else\n### 2. Quality check + normalise\n", encoding="utf-8")
    code = ("import importlib.util,sys\nfrom pathlib import Path\n"
            "s=importlib.util.spec_from_file_location('m',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
            "m.apply_reel_script_align(Path(sys.argv[2]),'p-reels-pip')\n")
    rr = subprocess.run([sys.executable, "-I", "-c", code, str(repo / "scripts" / "sync-skills.py"), str(drift)], capture_output=True, text=True)
    if rr.returncode == 0 or "WI2.72 transform cannot apply" not in rr.stderr:
        bad.append("sync transform did not fail fast on a missing anchor (rc=%d)" % rr.returncode)
    # index.json hashes cover the edited files
    idx = json.loads((repo / "skills" / "index.json").read_text(encoding="utf-8"))
    for r in RECIPES:
        f = repo / "skills" / r / "steps" / "02-transcribe.md"
        actual = "sha256:" + hashlib.sha256(f.read_bytes()).hexdigest()
        if idx["recipes"][r]["fileHashes"].get("steps/02-transcribe.md") != actual:
            bad.append("%s: index.json hash for steps/02-transcribe.md is stale" % r)
except Exception as exc:
    bad.append("error: %s" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi272_detail" == "ok" ]]; then
  pass "WI2.72 mis-heard caption words are corrected to the script, timings kept; no script = unchanged"
else
  fail "WI2.72 caption words checked against the script" "$wi272_detail"
fi
rm -rf "$wi272_root"

echo "=== Case 53: WI2.76 — caption groups keep phrases whole (no lone mid-clause fragment) ==="
# Smoke 21b showed a caption "FLOUR STILL": the planner split "She approved them with flour
# still on her hands," into three groups. The caption-planning step now writes
# work/caption_phrases.py (shipped by scripts/sync-skills.py), regroups the plan so no group
# ends on a preposition/article/conjunction/auxiliary and no 1-2 word mid-clause fragment is
# left (timings kept), and the plan guard fails on a split phrase. A whole plan is unchanged.
wi276_root="$(mktemp -d)"
wi276_detail="$(python3 - "$REPO_DIR" "$wi276_root" <<'PY'
import copy, hashlib, importlib.util, json, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
FILES = {"p-reels-spotlight": "steps/03-plan-edit.md", "p-reels-spotlight-heygen": "steps/03-plan-edit.md",
         "p-reels-pip": "steps/05-composite.md", "p-reels-pip-heygen": "steps/05-composite.md"}
OPEN = "cat > work/caption_phrases.py <<'PY'\n"
def say(g):
    return " ".join(w["w"] for w in g["words"])
def closes(w):
    t = re.sub(r"[\"')\]]+$", "", w["w"].strip())
    return bool(t) and t[-1] in ".,!?;:"
def fragments(groups):
    return [say(g) for i, g in enumerate(groups) if 0 < i < len(groups) - 1 and len(g["words"]) <= 2
            and not closes(groups[i - 1]["words"][-1]) and not closes(g["words"][-1])]
try:
    spec = importlib.util.spec_from_file_location("ss276", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    helpers = {}
    for r, rel in FILES.items():
        body = (repo / "skills" / r / rel).read_text(encoding="utf-8")
        if OPEN not in body:
            bad.append("%s: %s does not write work/caption_phrases.py" % (r, rel)); continue
        helpers[r] = body.split(OPEN, 1)[1].split("\nPY\n", 1)[0] + "\n"
        if "spotlight" in r:
            run_at = body.find("python3 work/caption_phrases.py saves/edit_plan.json")
            guard_at = body.find("Then run the mechanical guard")
            if run_at < 0 or not (body.index(OPEN) < run_at < guard_at):
                bad.append("%s: the plan is not regrouped after it is written and before the guard" % r)
            if '"work/caption_phrases.py", "--check"' not in body.split("Then run the mechanical guard", 1)[1]:
                bad.append("%s: the plan guard does not check for split phrases" % r)
            if "never\n   leave a lone 1–2 word fragment" not in body:
                bad.append("%s: rule 1 does not forbid a lone mid-clause fragment" % r)
        else:
            if 'python3 work/caption_phrases.py "$PW/plan.json"' not in body or \
               'python3 work/caption_phrases.py --check "$PW/plan.json" || exit 1' not in body:
                bad.append("%s: composite step does not regroup and check the premium plan" % r)
    if set(helpers.values()) != {ss._CAPTION_PHRASES_PY}:
        bad.append("helper differs across recipes or from sync-skills.py")
    helper = root / "caption_phrases.py"; helper.write_text(ss._CAPTION_PHRASES_PY, encoding="utf-8")
    fixture = json.loads((repo / "test" / "fixtures" / "wi276-smoke21b-caption-groups.json").read_text())
    orig = fixture["caption_groups"]
    plan = {"duration": fixture["duration"], "energy": "medium", "grade": "warm-amber", "cover_at": 20.0,
            "brand": {"bg": "#0F172A", "accent": "#F97316", "fg": "#F1F5F9"}, "takeovers": [],
            "caption_groups": orig, "sfx": []}
    wd = root / "smoke21b"; (wd / "work").mkdir(parents=True); (wd / "saves").mkdir()
    shutil.copy(helper, wd / "work" / "caption_phrases.py")
    pp = wd / "saves" / "edit_plan.json"; pp.write_text(json.dumps(plan), encoding="utf-8")
    guard = (repo / "skills" / "p-reels-spotlight" / "steps" / "03-plan-edit.md").read_text(encoding="utf-8")
    guard = guard.split("python3 - saves/edit_plan.json \"$DUR\" <<'PY'\n", 1)[1].split("\nPY\n", 1)[0] + "\n"
    (wd / "guard.py").write_text(guard, encoding="utf-8")
    g0 = subprocess.run([sys.executable, "-I", "guard.py", "saves/edit_plan.json", str(fixture["duration"])],
                        cwd=wd, capture_output=True, text=True)
    if g0.returncode == 0:
        bad.append("guard passed the smoke 21b plan with its FLOUR STILL fragment")
    c0 = subprocess.run([sys.executable, "-I", str(helper), "--check", "saves/edit_plan.json"], cwd=wd, capture_output=True, text=True)
    if c0.returncode == 0 or "'flour still'" not in c0.stderr:
        bad.append("--check did not name the 'flour still' fragment (rc=%d)" % c0.returncode)
    r = subprocess.run([sys.executable, "-I", str(helper), "saves/edit_plan.json"], cwd=wd, capture_output=True, text=True)
    if r.returncode != 0:
        bad.append("helper rc=%d %s" % (r.returncode, r.stderr.strip()[-300:]))
    got = json.loads(pp.read_text())["caption_groups"]
    print("REGROUPED " + " | ".join("[%s]" % say(g) for g in got), file=sys.stderr)
    home = [g for g in got if "flour" in say(g)]
    if len(home) != 1 or "flour still on her hands," not in say(home[0]):
        bad.append("'flour still' is not in the same group as 'on her hands': %r" % [say(g) for g in home])
    if any(say(g).lower() in ("flour still", "with flour still") for g in got):
        bad.append("a lone flour-still group survived")
    if fragments(got):
        bad.append("mid-clause fragments left: %r" % fragments(got))
    for i, g in enumerate(got[:-1]):
        if g["words"][-1]["w"].lower() in ("with", "a", "the", "of", "to", "and", "is"):
            bad.append("group ends on a phrase word: %r" % say(g))
    flat = lambda gs: [(w["w"], w["s"], w["e"]) for g in gs for w in g["words"]]
    if flat(got) != flat(orig):
        bad.append("words or word timings changed")
    if any(len(g["words"]) > 6 for g in got):
        bad.append("a group has more than 6 words")
    for a, b in zip(got, got[1:]):
        if a["style"] == b["style"]:
            bad.append("adjacent groups share style %s" % a["style"])
        if a["end"] > b["start"] + 1e-9:
            bad.append("groups overlap at %r" % say(b))
    for g in got:
        if sum(1 for w in g["words"] if w.get("em")) > 1:
            bad.append("more than one em word in %r" % say(g))
        if not (g["start"] <= g["words"][0]["s"] + 1e-9 and g["end"] >= g["words"][-1]["e"] - 1e-9):
            bad.append("group span does not hold its words: %r" % say(g))
    if got[0]["start"] != orig[0]["start"] or got[-1]["end"] != orig[-1]["end"]:
        bad.append("coverage of the bed changed")
    g1 = subprocess.run([sys.executable, "-I", "guard.py", "saves/edit_plan.json", str(fixture["duration"])],
                        cwd=wd, capture_output=True, text=True)
    if g1.returncode != 0 or "plan OK" not in g1.stdout:
        bad.append("guard failed the regrouped plan: %s" % (g1.stderr.strip()[-300:]))
    before = pp.read_bytes()
    r2 = subprocess.run([sys.executable, "-I", str(helper), "saves/edit_plan.json"], cwd=wd, capture_output=True, text=True)
    if r2.returncode != 0 or pp.read_bytes() != before:
        bad.append("second run is not a no-op")
    # a plan that already keeps phrases whole is left byte-for-byte unchanged
    def mk(lines):
        gs, t = [], 0.0
        for k, line in enumerate(lines):
            ws = []
            for x in line.split():
                ws.append({"w": x, "s": round(t, 3), "e": round(t + 0.3, 3), "em": False}); t += 0.32
            gs.append({"start": ws[0]["s"], "end": ws[-1]["e"], "style": k % 3, "words": ws})
        gs[1]["words"][0]["em"] = True
        return gs
    whole = dict(plan, caption_groups=mk(["She approved them", "with flour still on her hands,", "about 30 minutes",
                                          "a week.", "Here's how it works.", "Once a week,", "she just types"]))
    wp = wd / "saves" / "whole.json"; wp.write_text(json.dumps(whole, indent=2), encoding="utf-8")
    wb = wp.read_bytes()
    r3 = subprocess.run([sys.executable, "-I", str(helper), "saves/whole.json"], cwd=wd, capture_output=True, text=True)
    if r3.returncode != 0 or wp.read_bytes() != wb or "unchanged" not in r3.stdout:
        bad.append("a whole plan was changed (rc=%d %r)" % (r3.returncode, r3.stdout.strip()))
    # the sync transform is idempotent on the committed files and fails fast on a drifted anchor
    for rcp, rel in FILES.items():
        cp = root / "copy" / rcp; shutil.copytree(repo / "skills" / rcp / "steps", cp / "steps")
        if ss.apply_reel_caption_phrases(cp, rcp) != 0:
            bad.append("%s: committed %s is not what sync-skills.py writes" % (rcp, rel))
    drift = root / "drift" / "p-reels-spotlight"; (drift / "steps").mkdir(parents=True)
    (drift / "steps" / "03-plan-edit.md").write_text("Then run the mechanical guard, differently\n", encoding="utf-8")
    code = ("import importlib.util,sys\nfrom pathlib import Path\n"
            "s=importlib.util.spec_from_file_location('m',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
            "m.apply_reel_caption_phrases(Path(sys.argv[2]),'p-reels-spotlight')\n")
    rr = subprocess.run([sys.executable, "-I", "-c", code, str(repo / "scripts" / "sync-skills.py"), str(drift)], capture_output=True, text=True)
    if rr.returncode == 0 or "WI2.76 transform cannot apply" not in rr.stderr:
        bad.append("sync transform did not fail fast on a missing anchor (rc=%d)" % rr.returncode)
    # index.json hashes cover the edited files
    idx = json.loads((repo / "skills" / "index.json").read_text(encoding="utf-8"))
    for rcp, rel in FILES.items():
        actual = "sha256:" + hashlib.sha256((repo / "skills" / rcp / rel).read_bytes()).hexdigest()
        if idx["recipes"][rcp]["fileHashes"].get(rel) != actual:
            bad.append("%s: index.json hash for %s is stale" % (rcp, rel))
except Exception as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi276_detail" == "ok" ]]; then
  pass "WI2.76 caption groups keep phrases whole: 'flour still' joins 'on her hands', a whole plan is unchanged"
else
  fail "WI2.76 caption groups keep phrases whole" "$wi276_detail"
fi
rm -rf "$wi276_root"

echo "=== Case 54: WI2.78 — caption-phrase repair always restyles and clamps; pip runs it as code ==="
# Review of WI2.76: the helper only restyled and clamped overlaps when it regrouped, so a plan
# that was already whole but had two neighbouring groups with one style (or a tiny overlap)
# now failed --check and stopped a reel that used to render. The pip repair before P2 was only
# prose, and the --check ran even with CAPTIONS=off. "her"/"his" were not joiners, and a group
# with no words crashed with an IndexError. Timings never move.
wi278_root="$(mktemp -d)"
wi278_detail="$(python3 - "$REPO_DIR" "$wi278_root" <<'PY'
import hashlib, importlib.util, json, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
FILES = {"p-reels-spotlight": "steps/03-plan-edit.md", "p-reels-spotlight-heygen": "steps/03-plan-edit.md",
         "p-reels-pip": "steps/05-composite.md", "p-reels-pip-heygen": "steps/05-composite.md"}
def say(g):
    return " ".join(w["w"] for w in g["words"])
def mk(lines, styles=None):
    gs, t = [], 0.0
    for k, line in enumerate(lines):
        ws = []
        for x in line.split():
            ws.append({"w": x, "s": round(t, 3), "e": round(t + 0.3, 3), "em": False}); t += 0.32
        gs.append({"start": ws[0]["s"], "end": ws[-1]["e"], "style": (styles or [0, 1, 2])[k % len(styles or [0, 1, 2])],
                   "words": ws})
    return gs
def flat(gs):
    return [(w["w"], w["s"], w["e"]) for g in gs for w in g["words"]]
def run(helper, wd, *args):
    return subprocess.run([sys.executable, "-I", str(helper), *args], cwd=wd, capture_output=True, text=True)
try:
    spec = importlib.util.spec_from_file_location("ss278", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    helper = root / "caption_phrases.py"; helper.write_text(ss._CAPTION_PHRASES_PY, encoding="utf-8")
    wd = root / "wd"; wd.mkdir()
    # 1. a whole plan with two neighbouring groups of one style is repaired, not failed
    lines = ["She approved them", "with flour still on her hands,", "about 30 minutes", "a week."]
    same = mk(lines, styles=[0, 0, 1, 1])
    p1 = wd / "same.json"; p1.write_text(json.dumps({"caption_groups": same}), encoding="utf-8")
    if run(helper, wd, "--check", "same.json").returncode == 0:
        bad.append("--check passed equal neighbouring styles (fixture is wrong)")
    r1 = run(helper, wd, "same.json")
    got = json.loads(p1.read_text())["caption_groups"]
    if r1.returncode != 0:
        bad.append("equal styles: repair rc=%d %s" % (r1.returncode, r1.stderr.strip()[-200:]))
    if [say(g) for g in got] != lines or flat(got) != flat(same):
        bad.append("equal styles: groups or word timings changed: %r" % [say(g) for g in got])
    if any(a["style"] == b["style"] for a, b in zip(got, got[1:])):
        bad.append("equal styles: neighbours still share a style %r" % [g["style"] for g in got])
    if run(helper, wd, "--check", "same.json").returncode != 0:
        bad.append("equal styles: --check fails the repaired plan")
    # 2. a whole plan with a tiny overlap is clamped, not failed; word timings stay
    lap = mk(lines); lap[1]["end"] = round(lap[2]["start"] + 0.02, 3)
    p2 = wd / "lap.json"; p2.write_text(json.dumps({"caption_groups": lap}), encoding="utf-8")
    if run(helper, wd, "--check", "lap.json").returncode == 0:
        bad.append("--check passed an overlap (fixture is wrong)")
    r2 = run(helper, wd, "lap.json")
    got = json.loads(p2.read_text())["caption_groups"]
    if r2.returncode != 0:
        bad.append("overlap: repair rc=%d %s" % (r2.returncode, r2.stderr.strip()[-200:]))
    if flat(got) != flat(lap) or [say(g) for g in got] != lines:
        bad.append("overlap: words or word timings changed")
    if any(a["end"] > b["start"] + 1e-9 for a, b in zip(got, got[1:])):
        bad.append("overlap: groups still overlap")
    if got[1]["end"] != got[2]["start"]:
        bad.append("overlap: group end not clamped to the next start (%r)" % got[1]["end"])
    # 3. "her"/"his" never end a group mid-phrase: on her | hands
    for left, right in (("with flour still on her", "hands, about 30 minutes"), ("He set down his", "rolling pin, then smiled.")):
        gs = mk(["She approved them", left, right])
        pp = wd / "pos.json"; pp.write_text(json.dumps({"caption_groups": gs}), encoding="utf-8")
        c = run(helper, wd, "--check", "pos.json")
        if c.returncode == 0 or "ends inside a phrase" not in c.stderr:
            bad.append("--check passed %r | %r" % (left, right))
        r = run(helper, wd, "pos.json")
        got = json.loads(pp.read_text())["caption_groups"]
        if r.returncode != 0:
            bad.append("possessive: repair rc=%d %s" % (r.returncode, r.stderr.strip()[-200:]))
        if any(g["words"][-1]["w"].lower() in ("her", "his") for g in got[:-1]):
            bad.append("a group still ends on a possessive: %r" % [say(g) for g in got])
        if flat(got) != flat(gs):
            bad.append("possessive: words or word timings changed")
    # 4. a group with no words is a clear error, not an IndexError, in both modes
    empty = mk(["She approved them", "with flour still on her hands,", "about 30 minutes"])
    empty.insert(1, {"start": 0.95, "end": 0.96, "style": 2, "words": []})
    pe = wd / "empty.json"; pe.write_text(json.dumps({"caption_groups": empty}), encoding="utf-8")
    for args in (["empty.json"], ["--check", "empty.json"]):
        r = run(helper, wd, *args)
        if r.returncode != 1 or "group 1 has no words" not in r.stderr or "Traceback" in r.stderr:
            bad.append("empty group %s: rc=%d %r" % (args[0], r.returncode, r.stderr.strip()[-200:]))
    # 5. the WI2.76 fixture still regroups to [She approved them] [with flour still on her hands,]
    fixture = json.loads((repo / "test" / "fixtures" / "wi276-smoke21b-caption-groups.json").read_text())
    pf = wd / "fx.json"; pf.write_text(json.dumps({"caption_groups": fixture["caption_groups"]}), encoding="utf-8")
    r5 = run(helper, wd, "fx.json")
    got = [say(g) for g in json.loads(pf.read_text())["caption_groups"]]
    k = got.index("She approved them") if "She approved them" in got else -1
    if r5.returncode != 0 or k < 0 or got[k + 1] != "with flour still on her hands,":
        bad.append("WI2.76 fixture regrouped differently: %r" % got[max(k, 0):k + 2])
    if flat(json.loads(pf.read_text())["caption_groups"]) != flat(fixture["caption_groups"]):
        bad.append("WI2.76 fixture: words or word timings changed")
    # 6. pip step 05 runs the repair as code between P1 and P2; captions off skips repair and check
    REPAIR = 'if [ "$CAPTIONS" != off ]; then python3 work/caption_phrases.py "$PW/plan.json" || exit 1; fi\n'
    CHECK = 'if [ "$CAPTIONS" != off ]; then python3 work/caption_phrases.py --check "$PW/plan.json" || exit 1; fi\n'
    for rcp in ("p-reels-pip", "p-reels-pip-heygen"):
        body = (repo / "skills" / rcp / "steps" / "05-composite.md").read_text(encoding="utf-8")
        p1_at, rep_at = body.find("# 1) run P1 (plan) here"), body.find(REPAIR)
        p2_at = body.find("# 3) now run P2 → P4 only")
        if not (0 <= p1_at < rep_at < p2_at) or body.count(REPAIR) != 1:
            bad.append("%s: the repair is not a command between P1 and P2" % rcp)
        if body.count(CHECK) != 1 or body.find(CHECK) < p2_at:
            bad.append("%s: the --check after P4 is not skipped when captions are off" % rcp)
        if "# WI2.76: after P1 and before P2:" in body:
            bad.append("%s: the comment-only repair note is still there" % rcp)
        prem = (repo / "skills" / rcp / ".hub" / "c-reel-premium" / "SKILL.md").read_text(encoding="utf-8")
        if ss._CAPTION_PHRASES_P1_RULE_NEW not in prem or ss._CAPTION_PHRASES_P1_RULE_OLD in prem:
            bad.append("%s: c-reel-premium P1 prompt does not state the grouping rule" % rcp)
    plan = json.dumps({"caption_groups": mk(["She approved them with", "flour still", "on her hands,"])})
    for caps, want_rc, want_plan_changed in (("off", 0, False), ("on", 0, True)):
        sd = root / ("pip-" + caps); (sd / "work" / "premium").mkdir(parents=True)
        shutil.copy(helper, sd / "work" / "caption_phrases.py")
        (sd / "work" / "premium" / "plan.json").write_text(plan, encoding="utf-8")
        sh = subprocess.run(["bash", "-c", "PW=work/premium; CAPTIONS=%s\n%s%s" % (caps, REPAIR, CHECK)],
                            cwd=sd, capture_output=True, text=True)
        changed = (sd / "work" / "premium" / "plan.json").read_text(encoding="utf-8") != plan
        if sh.returncode != want_rc or changed != want_plan_changed:
            bad.append("pip CAPTIONS=%s: rc=%d plan changed=%s %s" % (caps, sh.returncode, changed, sh.stderr.strip()[-200:]))
    # 7. the sync transform is idempotent on the committed files; index.json hashes are current
    idx = json.loads((repo / "skills" / "index.json").read_text(encoding="utf-8"))
    for rcp, rel in FILES.items():
        cp = root / "copy" / rcp; shutil.copytree(repo / "skills" / rcp / "steps", cp / "steps")
        rels = [rel]
        if "pip" in rcp:
            (cp / ".hub" / "c-reel-premium").mkdir(parents=True)
            shutil.copy(repo / "skills" / rcp / ".hub" / "c-reel-premium" / "SKILL.md", cp / ".hub" / "c-reel-premium")
            rels.append(".hub/c-reel-premium/SKILL.md")
        if ss.apply_reel_caption_phrases(cp, rcp) != 0:
            bad.append("%s: committed files are not what sync-skills.py writes" % rcp)
        for f in rels:
            actual = "sha256:" + hashlib.sha256((repo / "skills" / rcp / f).read_bytes()).hexdigest()
            if idx["recipes"][rcp]["fileHashes"].get(f) != actual:
                bad.append("%s: index.json hash for %s is stale" % (rcp, f))
except Exception as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi278_detail" == "ok" ]]; then
  pass "WI2.78 caption-phrase repair fixes styles/overlaps on a whole plan, joins her/his, pip repairs as code"
else
  fail "WI2.78 caption-phrase repair always restyles and clamps" "$wi278_detail"
fi
rm -rf "$wi278_root"

echo "=== Case 55: WI2.79 — caption repair refuses bad timings; pip step 05 no longer invites a second P1 ==="
# Review of WI2.78: tidy() clamped every overlap, so a plan with groups out of order (or two
# groups with one start) became a group with end <= start (start 1, end 0.5) and --check passed.
# Pip step 05 kept the WI2.64 line "# run P1 -> P4 here" right after "then P2 -> P4", so an
# engine could re-run P1 and overwrite the repaired plan. Missing plan.json or a group without
# start/end was a traceback.
wi279_root="$(mktemp -d)"
wi279_detail="$(python3 - "$REPO_DIR" "$wi279_root" <<'PY'
import importlib.util, json, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
def mk(lines):
    gs, t = [], 0.0
    for k, line in enumerate(lines):
        ws = []
        for x in line.split():
            ws.append({"w": x, "s": round(t, 3), "e": round(t + 0.3, 3), "em": False}); t += 0.32
        gs.append({"start": ws[0]["s"], "end": ws[-1]["e"], "style": k % 3, "words": ws})
    return gs
def run(helper, wd, *args):
    return subprocess.run([sys.executable, "-I", str(helper), *args], cwd=wd, capture_output=True, text=True)
def refused(helper, wd, name, body, want, label):
    # both modes exit 1 with a clear message, no traceback, and repair leaves the file alone
    pf = wd / name
    raw = json.dumps({"caption_groups": body}) if body is not None else None
    for args in ([name], ["--check", name]):
        if raw is not None:
            pf.write_text(raw, encoding="utf-8")
        elif pf.exists():
            pf.unlink()
        r = run(helper, wd, *args)
        if r.returncode != 1 or want not in r.stderr or "Traceback" in r.stderr:
            bad.append("%s %s: rc=%d %r" % (label, args[0], r.returncode, r.stderr.strip()[-240:]))
        if raw is not None and pf.read_text(encoding="utf-8") != raw:
            bad.append("%s %s: the refused plan was rewritten" % (label, args[0]))
try:
    spec = importlib.util.spec_from_file_location("ss279", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    pip = (repo / "skills" / "p-reels-pip" / "steps" / "05-composite.md").read_text(encoding="utf-8")
    marker = "cat > work/caption_phrases.py <<'PY'\n"
    shipped = pip[pip.index(marker) + len(marker):pip.index("\nPY\n", pip.index(marker)) + 1]
    if shipped != ss._CAPTION_PHRASES_PY:
        bad.append("the helper in pip step 05 is not the sync-skills.py helper")
    helper = root / "caption_phrases.py"; helper.write_text(shipped, encoding="utf-8")
    wd = root / "wd"; wd.mkdir()
    lines = ["She approved them", "with flour still on her hands,", "about 30 minutes", "a week."]
    # 1. a group that ends at or before its start is refused
    g = mk(lines); g[2]["end"] = g[2]["start"]
    refused(helper, wd, "zero.json", g, "group 2 ends at", "end<=start")
    # 2. starts that go backwards are refused (the review's start 1 / end 0.5 case)
    g = mk(lines); g[1], g[2] = g[2], g[1]
    refused(helper, wd, "back.json", g, "must be in time order", "backwards starts")
    g = mk(lines); g[2]["start"] = g[1]["start"]
    refused(helper, wd, "same.json", g, "group 2 starts at", "equal starts")
    # 3. a group without start/end, and a missing plan, are clear errors
    g = mk(lines); del g[1]["end"]
    refused(helper, wd, "noend.json", g, "group 1 has no start/end time", "missing end")
    g = mk(lines); g[0].pop("start")
    refused(helper, wd, "nostart.json", g, "group 0 has no start/end time", "missing start")
    refused(helper, wd, "plan.json", None, "plan not found", "missing plan.json")
    # 4. a clean plan stays byte-identical in repair mode and passes --check
    clean = mk(lines)
    pc = wd / "clean.json"; raw = json.dumps({"caption_groups": clean, "x": 1}, indent=3) + "\n"
    pc.write_bytes(raw.encode("utf-8"))
    r = run(helper, wd, "clean.json")
    if r.returncode != 0 or pc.read_bytes() != raw.encode("utf-8") or "plan unchanged" not in r.stdout:
        bad.append("clean plan: rc=%d byte-identical=%s %r" % (r.returncode, pc.read_bytes() == raw.encode("utf-8"), (r.stdout + r.stderr)[-200:]))
    if run(helper, wd, "--check", "clean.json").returncode != 0:
        bad.append("clean plan: --check failed")
    # 5. an in-order overlap is still clamped (WI2.78 kept), never to end <= start
    lap = mk(lines); lap[1]["end"] = round(lap[2]["start"] + 0.05, 3)
    pl = wd / "lap.json"; pl.write_text(json.dumps({"caption_groups": lap}), encoding="utf-8")
    r = run(helper, wd, "lap.json")
    got = json.loads(pl.read_text())["caption_groups"]
    if r.returncode != 0 or any(x["end"] <= x["start"] or x["end"] > y["start"] for x, y in zip(got, got[1:])):
        bad.append("in-order overlap: rc=%d %r" % (r.returncode, [(x["start"], x["end"]) for x in got]))
    # 6. pip step 05: nothing after the repair asks for P1 again; P2 -> P4 follows it
    REPAIR = 'if [ "$CAPTIONS" != off ]; then python3 work/caption_phrases.py "$PW/plan.json" || exit 1; fi\n'
    CHECK = 'if [ "$CAPTIONS" != off ]; then python3 work/caption_phrases.py --check "$PW/plan.json" || exit 1; fi\n'
    for rcp in ("p-reels-pip", "p-reels-pip-heygen"):
        body = (repo / "skills" / rcp / "steps" / "05-composite.md").read_text(encoding="utf-8")
        at = body.find(REPAIR)
        if ss._CAPTION_PHRASES_PIP_P1_ANCHOR in body:
            bad.append("%s: the WI2.64 'run P1 -> P4 here' line is still there" % rcp)
        if at < 0 or "run P1" in body[at:] or body.count(ss._CAPTION_PHRASES_PIP_P1_NOTE) != 1:
            bad.append("%s: a P1 instruction follows the repair" % rcp)
        if not body.find(ss._CAPTION_PHRASES_PIP_P1_NOTE + ss._CAPTION_PHRASES_PIP_TAIL_ANCHOR + ss._CAPTION_PHRASES_PIP_CHECK) >= 0:
            bad.append("%s: note, WI2.64 plan clamp and --check are not in order" % rcp)
    # 7. the transform rebuilds the committed file from the WI2.78 state and from the bare
    #    WI2.64 line, replaces an older helper body, and is idempotent
    base = pip.replace(ss._CAPTION_PHRASES_PIP_P1_NOTE, ss._CAPTION_PHRASES_PIP_P1_ANCHOR, 1)
    wi278 = pip.replace(ss._CAPTION_PHRASES_PIP_P1_NOTE, ss._CAPTION_PHRASES_PIP_P1_NOTE_WI278 + ss._CAPTION_PHRASES_PIP_P1_ANCHOR, 1)
    older = pip.replace(shipped, shipped.replace("import json, os, re, sys", "import json, re, sys"), 1)
    for label, start in (("bare WI2.64 line", base), ("WI2.78 note", wi278), ("older helper", older)):
        cp = root / "tx" / label.replace(" ", "-"); (cp / "steps").mkdir(parents=True)
        (cp / "steps" / "05-composite.md").write_text(start, encoding="utf-8")
        ss.apply_reel_caption_phrases(cp, "p-reels-pip")
        once = (cp / "steps" / "05-composite.md").read_text(encoding="utf-8")
        n = ss.apply_reel_caption_phrases(cp, "p-reels-pip")
        if once != pip or n != 0:
            bad.append("transform from %s: equal=%s second-apply=%d" % (label, once == pip, n))
    cp = root / "tx" / "drift"; (cp / "steps").mkdir(parents=True)
    (cp / "steps" / "05-composite.md").write_text(base.replace(ss._CAPTION_PHRASES_PIP_P1_ANCHOR, "# drifted\n"), encoding="utf-8")
    try:
        ss.apply_reel_caption_phrases(cp, "p-reels-pip"); bad.append("a drifted P1 line did not fail the sync")
    except SystemExit as exc:
        if "WI2.79" not in str(exc) or "WI2.76" in str(exc):
            bad.append("drifted P1 line error does not name WI2.79: %s" % exc)
    # 8. the CAPTIONS guard lines run under zsh as well as bash
    shells = [s for s in ("bash", "zsh") if shutil.which(s)]
    if "zsh" not in shells and sys.platform == "darwin":
        bad.append("zsh not found on macOS")
    plan = json.dumps({"caption_groups": mk(["She approved them with", "flour still", "on her hands,"])})
    for sh in shells:
        for caps, has_plan, want_rc, want_changed in (("off", True, 0, False), ("on", True, 0, True),
                                                      ("on", False, 1, False), ("off", False, 0, False)):
            sd = root / ("%s-%s-%s" % (sh, caps, has_plan)); (sd / "work" / "premium").mkdir(parents=True)
            shutil.copy(helper, sd / "work" / "caption_phrases.py")
            pp = sd / "work" / "premium" / "plan.json"
            if has_plan:
                pp.write_text(plan, encoding="utf-8")
            r = subprocess.run([sh, "-c", "PW=work/premium; CAPTIONS=%s\n%s%s" % (caps, REPAIR, CHECK)],
                               cwd=sd, capture_output=True, text=True)
            changed = has_plan and pp.read_text(encoding="utf-8") != plan
            if r.returncode != want_rc or changed != want_changed or "Traceback" in r.stderr:
                bad.append("%s CAPTIONS=%s plan=%s: rc=%d changed=%s %r" % (sh, caps, has_plan, r.returncode, changed, r.stderr.strip()[-160:]))
            if not has_plan and caps == "on" and "plan not found" not in r.stderr:
                bad.append("%s: missing plan is not a clear message" % sh)
except Exception as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi279_detail" == "ok" ]]; then
  pass "WI2.79 caption repair refuses end<=start and backwards starts, clear errors, pip has no second P1, zsh guard"
else
  fail "WI2.79 caption repair refuses bad timings; pip step 05 no longer invites a second P1" "$wi279_detail"
fi
rm -rf "$wi279_root"

echo "=== Case 56: WI2.77 — the script prompt reaches mlx_whisper as two arguments; a fewer-words fix keeps caption time ==="
# Review of WI2.72: ${SCRIPT_PROMPT:+--initial-prompt "$SCRIPT_PROMPT"} stays ONE argument under
# zsh (the engine's shell), so mlx_whisper took it for a second audio file and the prompt was
# dropped with exit 0. And a replace with fewer script words than heard (heard "New York",
# script "NYC") dropped the first entry, leaving its time with no caption.
wi277_root="$(mktemp -d)"
wi277_detail="$(python3 - "$REPO_DIR" "$wi277_root" <<'PY'
import importlib.util, json, os, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
RECIPES = ("p-reels-spotlight", "p-reels-spotlight-heygen", "p-reels-pip", "p-reels-pip-heygen")
try:
    spec = importlib.util.spec_from_file_location("ss277", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    helper = root / "script_align.py"; helper.write_text(ss._SCRIPT_ALIGN_PY, encoding="utf-8")
    # 1. the mlx_whisper block, run as written, under bash, sh and zsh with a stub that prints argv
    stub = root / "bin"; stub.mkdir()
    (stub / "mlx_whisper").write_text('#!/bin/sh\nfor a in "$@"; do printf \'<%s>\\n\' "$a"; done\n', encoding="utf-8")
    os.chmod(stub / "mlx_whisper", 0o755)
    base = ["prior/voice_track.mp4", "--model", "mlx-community/whisper-small-mlx", "--output-dir", "work",
            "--output-format", "json"]
    script = "She approved them with flour still on her hands, about thirty minutes a week."
    shells = [sh for sh in ("bash", "sh", "zsh") if shutil.which(sh)]
    if "bash" not in shells or "sh" not in shells:
        bad.append("bash and sh must both be present (found %r)" % shells)
    def argv_of(shell, block, with_script):
        wd = root / ("run-%s-%d" % (shell, with_script)); shutil.rmtree(wd, ignore_errors=True)
        (wd / "work").mkdir(parents=True); shutil.copy(helper, wd / "work" / "script_align.py")
        if with_script:
            (wd / "inputs" / "script").mkdir(parents=True)
            (wd / "inputs" / "script" / "script.txt").write_text(script, encoding="utf-8")
        env = dict(os.environ, PATH=str(stub) + os.pathsep + os.environ.get("PATH", ""))
        r = subprocess.run([shell, "-c", block], cwd=wd, env=env, capture_output=True, text=True)
        if r.returncode != 0:
            bad.append("%s: block rc=%d %s" % (shell, r.returncode, r.stderr.strip()[-200:]))
        return [ln[1:-1] for ln in r.stdout.splitlines() if ln.startswith("<")]
    for rcp in RECIPES:
        body = (repo / "skills" / rcp / "steps" / "02-transcribe.md").read_text(encoding="utf-8")
        if "${SCRIPT_PROMPT:+" in body:
            bad.append("%s: the one-word ${SCRIPT_PROMPT:+...} form is still in the step" % rcp)
        if ss._SCRIPT_ALIGN_MLX_NEW not in body:
            bad.append("%s: the explicit-branch mlx_whisper block is not in the step" % rcp); continue
        block = ss._SCRIPT_ALIGN_MLX_NEW
        for shell in shells:
            got = argv_of(shell, block, True)
            if got != base + ["--initial-prompt", script]:
                bad.append("%s/%s: with a script mlx_whisper got %r" % (rcp, shell, got))
            got0 = argv_of(shell, block, False)
            if got0 != base:
                bad.append("%s/%s: with no script mlx_whisper got %r" % (rcp, shell, got0))
    if "zsh" in shells:  # the stub really tells the old form apart: zsh gave it one argument
        old = argv_of("zsh", ss._SCRIPT_ALIGN_MLX_WI272, True)
        if old != base + ["--initial-prompt " + script]:
            bad.append("stub check: the old form under zsh gave %r, expected one joined argument" % old)
    # 2. script_align: fewer, more and equal script words
    def run(name, heard, script_text):
        wd = root / name; (wd / "work").mkdir(parents=True); (wd / "inputs" / "script").mkdir(parents=True)
        (wd / "inputs" / "script" / "script.txt").write_text(script_text, encoding="utf-8")
        words = [{"text": t, "start": s, "end": e} for t, s, e in heard]
        (wd / "work" / "words.json").write_text(json.dumps(words), encoding="utf-8")
        r = subprocess.run([sys.executable, "-I", str(helper), "work/words.json"], cwd=wd, capture_output=True, text=True)
        if r.returncode != 0:
            bad.append("%s: rc=%d %s" % (name, r.returncode, r.stderr.strip()[-200:]))
        return [(w["text"], w["start"], w["end"]) for w in json.loads((wd / "work" / "words.json").read_text())]
    pre = [("I", 0.0, 0.2), ("moved", 0.2, 0.5), ("to", 0.5, 0.6)]
    post = [("last", 1.4, 1.7), ("summer", 1.7, 2.1), ("with", 2.1, 2.3), ("my", 2.3, 2.4), ("family.", 2.4, 2.9)]
    tail = "last summer with my family."
    got = run("fewer", pre + [("New", 0.6, 0.9), ("York", 0.9, 1.3)] + post, "I moved to NYC " + tail)
    if got != pre + [("NYC", 0.6, 1.3)] + post:
        bad.append("fewer words (word entries): %r" % got)
    got = run("fewer_punct", pre + [("New", 0.6, 0.9), ("York,", 0.9, 1.3)] + post, "I moved to NYC, " + tail)
    if got != pre + [("NYC,", 0.6, 1.3)] + post:
        bad.append("fewer words keeps trailing punctuation: %r" % got)
    got = run("fewer_three", pre + [("the", 0.6, 0.7), ("big", 0.7, 0.9), ("apple", 0.9, 1.3)] + post,
              "I moved to NYC " + tail)
    if got != pre + [("NYC", 0.6, 1.3)] + post:
        bad.append("three heard words for one script word: %r" % got)
    segs = [(" I moved to New", 0.0, 0.9), (" York last summer", 0.9, 2.1), (" with my family.", 2.1, 2.9)]
    got = run("fewer_segments", segs, "I moved to NYC " + tail)
    if got != [("I moved to NYC last summer", 0.0, 2.1), ("with my family.", 2.1, 2.9)]:
        bad.append("fewer words across segments: %r" % got)
    got = run("more", pre + [("NYC", 0.6, 1.3)] + post, "I moved to New York " + tail)
    if got != pre + [("New York", 0.6, 1.3)] + post:
        bad.append("more words: %r" % got)
    got = run("equal", pre + [("flower", 0.6, 0.9), ("steel", 0.9, 1.3)] + post, "I moved to flour still " + tail)
    if got != pre + [("flour", 0.6, 0.9), ("still", 0.9, 1.3)] + post:
        bad.append("equal words: %r" % got)
    # 3. the transform upgrades the WI2.72 text and the pre-WI2.72 text to the committed step, idempotently
    for rcp in RECIPES:
        cur = (repo / "skills" / rcp / "steps" / "02-transcribe.md").read_text(encoding="utf-8")
        cc = root / "committed" / rcp; shutil.copytree(repo / "skills" / rcp / "steps", cc / "steps")
        if ss.apply_reel_script_align(cc, rcp) != 0:
            bad.append("%s: committed step is not what sync-skills.py writes" % rcp); continue
        h, rest = cur.split(ss._SCRIPT_ALIGN_OPEN, 1)
        wi272 = (h + ss._SCRIPT_ALIGN_OPEN + "# WI2.72 helper\nprint('old')\nPY\n" + rest.split("\nPY\n", 1)[1])
        wi272 = wi272.replace(ss._SCRIPT_ALIGN_MLX_NEW, ss._SCRIPT_ALIGN_MLX_WI272).replace(
            ss._SCRIPT_ALIGN_CHECK, ss._SCRIPT_ALIGN_CHECK_WI272)
        before = (cur.replace(ss._SCRIPT_ALIGN_SECTION, "").replace(ss._SCRIPT_ALIGN_CHECK, "")
                  .replace(ss._SCRIPT_ALIGN_MLX_NEW, ss._SCRIPT_ALIGN_MLX_OLD))
        for label, text in (("WI2.72", wi272), ("pre-WI2.72", before)):
            if text == cur:
                bad.append("%s: %s fixture equals the current text" % (rcp, label)); continue
            d = root / "up" / label / rcp; (d / "steps").mkdir(parents=True)
            (d / "steps" / "02-transcribe.md").write_text(text, encoding="utf-8")
            n1 = ss.apply_reel_script_align(d, rcp); n2 = ss.apply_reel_script_align(d, rcp)
            if (d / "steps" / "02-transcribe.md").read_text(encoding="utf-8") != cur or (n1, n2) != (1, 0):
                bad.append("%s: %s text did not upgrade to the committed step once (%d, %d)" % (rcp, label, n1, n2))
except Exception as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi277_detail" == "ok" ]]; then
  pass "WI2.77 script prompt is two arguments in bash/sh/zsh; a fewer-words fix keeps one caption over the heard time"
else
  fail "WI2.77 script prompt and caption timing" "$wi277_detail"
fi
rm -rf "$wi277_root"

echo "=== Case 57: WI2.73 — the chat mock-up finishes typing and holds the full line before the cut ==="
# Smoke 22 (R-78X6, p-reels-pip): a frame showed "Here's what's happening t" in the chat mock-up.
# The c-typing-ui typing window ended at DURATION*0.88/TYPING_SPEED, clamped only to DURATION-0.4,
# so a short scene or a slow TYPING_SPEED held the finished line for 0.4 s or less. Every vendored
# typing-scene.html now computes the window in typingWindow(): typing ends 0.6 s before the clip
# ends (>= 0.5 s of frames show the whole line); a clip too short to type in shows it at once.
wi273_root="$(mktemp -d)"
wi273_detail="$(python3 - "$REPO_DIR" "$wi273_root" <<'PY'
import importlib.util, json, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
HOLD, FPS = 0.5, 30
try:
    spec = importlib.util.spec_from_file_location("ss273", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    copies = sorted((repo / "skills").glob("*/.hub/c-typing-ui/templates/typing-scene.html"))
    names = {c.parts[-5] for c in copies}
    for need in ("p-reels-pip", "p-reels-pip-heygen", "p-reels-spotlight", "p-reels-spotlight-heygen"):
        if need not in names:
            bad.append("%s: no vendored c-typing-ui typing-scene.html" % need)
    for c in copies:
        body = c.read_text(encoding="utf-8")
        if ss.TYPING_WINDOW_JS not in body:
            bad.append("%s: typing window is not the WI2.73 typingWindow()" % c.relative_to(repo))
        if "DURATION - 0.4" in body:
            bad.append("%s: the old DURATION - 0.4 clamp is still there" % c.relative_to(repo))
        doc = (c.parent.parent / "SKILL.md").read_text(encoding="utf-8")
        if ss._TYPING_SKILL_NOTE not in doc:
            bad.append("%s: SKILL.md does not state the hold" % c.parent.parent.relative_to(repo))
    # Run the shipped window (and the old one) in node over a grid of durations and speeds, then
    # sample every rendered frame (t = k/FPS, k < DUR*FPS) the way the template does: the typed
    # count is round(len * (t - start) / (end - start)), clamped to [0, len].
    grid = [round(0.1 * i, 2) for i in range(1, 121)]
    speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 0.0, -1.0]
    js = """
const DURATION = 0, TYPING_SPEED = 1;
%s
const out = [];
for (const d of %s) for (const s of %s) {
  let w; try { w = WINDOW(d, s); } catch (e) { w = {err: String(e)}; }
  out.push([d, s, w.start, w.end, w.err || null]);
}
console.log(JSON.stringify(out));
"""
    def run(src, name):
        f = root / (name + ".js"); f.write_text(js % (src, json.dumps(grid), json.dumps(speeds)), encoding="utf-8")
        r = subprocess.run(["node", str(f)], capture_output=True, text=True)
        if r.returncode != 0:
            bad.append("%s: node rc=%d %s" % (name, r.returncode, r.stderr.strip()[-300:])); return []
        return json.loads(r.stdout)
    def shortfalls(rows, name):
        out = []
        for d, s, start, end, err in rows:
            if err or start is None or end is None:
                out.append("%s d=%s s=%s error %s" % (name, d, s, err)); continue
            if not (0 <= start <= end <= d):
                out.append("%s d=%s s=%s window %.3f..%.3f" % (name, d, s, start, end)); continue
            L = 59
            frames = [k / FPS for k in range(int(round(d * FPS)))]
            def typed(t):
                if t >= end: return L
                if t < start: return 0
                return min(L, max(0, round(L * (t - start) / (end - start))))
            full = [t for t in frames if typed(t) == L]
            need = min(HOLD, d)  # a clip shorter than the hold shows the whole line throughout
            if len(full) / FPS + 1e-9 < need - 1.0 / FPS:
                out.append("%s d=%s s=%s full line on %d frame(s)" % (name, d, s, len(full)))
        return out
    new_src = "function WINDOW(duration, speed) {\n" + ss.TYPING_WINDOW_JS.replace(
        "    var typeWin   = typingWindow(DURATION, TYPING_SPEED);\n", "").replace(
        "    var typeStart = typeWin.start;\n", "").replace("    var typeEnd   = typeWin.end;\n", "") + \
        "return typingWindow(duration, speed);\n}\n"
    got = shortfalls(run(new_src, "new"), "new")
    if got:
        bad.append("WI2.73 window: " + "; ".join(got[:5]))
    old_src = ("function WINDOW(DURATION, TYPING_SPEED) {\n" + ss._TYPING_WINDOW_OLD +
               "return {start: typeStart, end: typeEnd};\n}\n")
    old_rows = run(old_src, "old")
    if not any(m.startswith("old d=3 s=1 ") for m in shortfalls(old_rows, "old")):  # node prints 3.0 as 3
        bad.append("sanity: the old window was not caught short on a 3.0 s scene at speed 1.0")
    # The transform upgrades the old template + SKILL.md once and is then a no-op; a drifted copy fails fast.
    for c in copies[:1]:
        comp = c.parent.parent
        d = root / "up" / "r" / ".hub" / "c-typing-ui"; shutil.copytree(comp, d)
        tpl, doc = d / ss.TYPING_SCENE_FILE, d / ss.TYPING_SKILL_FILE
        tpl.write_text(c.read_text(encoding="utf-8").replace(ss.TYPING_WINDOW_JS, ss._TYPING_WINDOW_OLD), encoding="utf-8")
        doc.write_text(doc.read_text(encoding="utf-8").replace(ss._TYPING_SKILL_NOTE, ""), encoding="utf-8")
        n1 = ss.apply_typing_hold(root / "up" / "r", "fixture"); n2 = ss.apply_typing_hold(root / "up" / "r", "fixture")
        if (n1, n2) != (2, 0) or tpl.read_text(encoding="utf-8") != c.read_text(encoding="utf-8") \
                or doc.read_text(encoding="utf-8") != (comp / "SKILL.md").read_text(encoding="utf-8"):
            bad.append("transform did not upgrade the old copy to the committed one once (%d, %d)" % (n1, n2))
        tpl.write_text("<template>drifted</template>\n", encoding="utf-8")
        try:
            ss.apply_typing_hold(root / "up" / "r", "fixture")
            bad.append("transform did not fail on a copy without its anchor")
        except SystemExit:
            pass
except Exception as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi273_detail" == "ok" ]]; then
  pass "WI2.73 typing scenes finish typing and hold the full line >= 0.5 s before the cut, every recipe"
else
  fail "WI2.73 typing scene holds the full line before the cut" "$wi273_detail"
fi
rm -rf "$wi273_root"

echo "=== Case 58: WI2.80 — every scripts/<file> a recipe step names ships in that recipe's bundle ==="
# Observed 2026-10-21 (WI2.73): p-reels-pip step 04 (and its p-reels-pip-heygen copies, and the split
# step 04 copies) told the agent to run "$TYPING_UI_DIR/scripts/render.sh --text ... --duration ...".
# No c-typing-ui copy ships render.sh (only render-sample.sh, a fixed demo), so agents had to work the
# render out by hand. Step 04 now names the real usage (fill the template + hyperframes render), and
# every c-typing-ui SKILL.md describes the shipped typingWindow() timing, not "text.length × speed"
# or a #char-count element the template never had.
wi280_root="$(mktemp -d)"
wi280_detail="$(python3 - "$REPO_DIR" "$wi280_root" <<'PY'
import importlib.util, re, shutil, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
# Gaps that predate WI2.80 (the c-audio / c-heygen / c-ai-media / c-ffmpeg scripts are not vendored
# into these recipes). Listed exactly so a NEW missing script still fails, and an entry that gets
# fixed must be removed from this list (a stale entry fails too).
KNOWN_GAPS = {
    ("p-clone-reel", "steps/01-ingest-reference.md", "transcribe.sh"),
    ("p-clone-reel", "steps/03-generate-narration.md", "render.py"),
    ("p-longform", "steps/02-avatar-render.md", "render.py"),
    ("p-longform", "steps/03-transcribe.md", "transcribe.sh"),
    ("p-longform", "steps/04-build-visuals.md", "generate.py"),
    ("p-longform", "steps/06-composite.md", "build-segments.py"),
}
REF = re.compile(r"(?<![\w.-])scripts/([A-Za-z0-9_.-]+\.(?:sh|py|mjs|cjs|js|ts))")
def missing_refs(skills):
    out = set()
    for recipe in sorted(p for p in skills.iterdir() if p.is_dir()):
        shipped = {f.name for f in recipe.rglob("*") if f.is_file() and f.parent.name == "scripts"}
        for step in sorted(recipe.rglob("*.md")):
            rel = step.relative_to(recipe)
            if "steps" not in rel.parts:
                continue
            for m in REF.finditer(step.read_text(encoding="utf-8")):
                if m.group(1) not in shipped:
                    out.add((recipe.name, rel.as_posix(), m.group(1)))
    return out
try:
    spec = importlib.util.spec_from_file_location("ss280", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    skills = repo / "skills"
    got = missing_refs(skills)
    new = sorted(got - KNOWN_GAPS)
    if new:
        bad.append("step names a script its recipe does not ship: " +
                   ", ".join("%s/%s -> scripts/%s" % g for g in new[:8]))
    stale = sorted(KNOWN_GAPS - got)
    if stale:
        bad.append("KNOWN_GAPS entry now resolves; remove it: " + ", ".join("%s/%s" % g[:2] for g in stale))
    for need in ("p-reels-pip", "p-reels-pip-heygen", "p-reels-split", "p-reels-split-heygen"):
        if not list((skills / need).rglob("steps/04-build-*.md")):
            bad.append("%s: no step 04 found" % need)
    steps04 = [p for p in sorted(skills.glob("*/steps/04-build-*.md")) + sorted(skills.glob("*/.hub/*/steps/04-build-*.md"))
               if p.name in ss._STEP_TYPING_RENDER_EDITS]
    if len(steps04) != 6:
        bad.append("expected 6 pip/split step 04 copies, found %d" % len(steps04))
    for step in steps04:
        body = step.read_text(encoding="utf-8")
        if "typing-scene.html" not in body or "npx hyperframes@0.7.5 render" not in body:
            bad.append("%s: step 04 does not name the typing template + hyperframes render" % step.relative_to(repo))
    docs = sorted(skills.glob("*/.hub/c-typing-ui/SKILL.md"))
    if len(docs) < 8:
        bad.append("expected 8 vendored c-typing-ui SKILL.md copies, found %d" % len(docs))
    for doc in docs:
        body = doc.read_text(encoding="utf-8")
        tpl = (doc.parent / "templates" / "typing-scene.html").read_text(encoding="utf-8")
        if "typingWindow(duration, speed)" not in body or "function typingWindow(duration, speed)" not in tpl:
            bad.append("%s: does not describe typingWindow(duration, speed)" % doc.relative_to(repo))
        if "text.length × speed" in body:
            bad.append("%s: still says text.length × speed" % doc.relative_to(repo))
        for el in set(re.findall(r"`#([A-Za-z][\w-]*)`", body)):
            if re.fullmatch(r"[0-9A-Fa-f]{3,8}", el):
                continue  # a colour, not an element
            if 'id="%s"' % el not in tpl:
                bad.append("%s: names #%s, which typing-scene.html does not have" % (doc.relative_to(repo), el))
        if '.replace("\\n", "&#10;")' not in body or "gsap.min.js" not in body or "BOTTOM_TAG_DISPLAY" not in body:
            bad.append("%s: standalone usage misses &#10; newlines, BOTTOM_TAG_DISPLAY or gsap.min.js" % doc.relative_to(repo))
    # The check really catches the old step: restore the pre-WI2.80 text in a copy and scan it.
    up = root / "skills"
    for rec in ("p-reels-pip", "p-reels-split-heygen"):
        shutil.copytree(skills / rec, up / rec)
    for name, (old, newtxt) in ss._STEP_TYPING_RENDER_EDITS.items():
        for step in up.rglob(name):
            step.write_text(step.read_text(encoding="utf-8").replace(newtxt, old), encoding="utf-8")
    old_miss = missing_refs(up)
    for want in (("p-reels-pip", "steps/04-build-background.md", "render.sh"),
                 ("p-reels-split-heygen", "steps/04-build-top.md", "render.sh"),
                 ("p-reels-split-heygen", ".hub/p-reels-split/steps/04-build-top.md", "render.sh")):
        if want not in old_miss:
            bad.append("sanity: the old step text was not caught (%s/%s)" % want[:2])
    # Restore the old c-typing-ui SKILL.md text too; the transform upgrades both once, then is a no-op.
    for doc in up.rglob(".hub/c-typing-ui/SKILL.md"):
        text = doc.read_text(encoding="utf-8")
        for old, newtxt in ss._TYPING_SKILL_RENDER_EDITS:
            text = text.replace(newtxt, old)
        doc.write_text(text, encoding="utf-8")
    for rec in ("p-reels-pip", "p-reels-split-heygen"):
        n1 = ss.apply_typing_render_usage(up / rec, rec); n2 = ss.apply_typing_render_usage(up / rec, rec)
        want = 2 if rec == "p-reels-pip" else 3
        if (n1, n2) != (want, 0):
            bad.append("transform on %s changed (%d, %d) file(s), expected (%d, 0)" % (rec, n1, n2, want))
        for f in sorted(p for p in (up / rec).rglob("*") if p.is_file()):
            if f.read_bytes() != (skills / rec / f.relative_to(up / rec)).read_bytes():
                bad.append("transform output differs from the committed %s/%s" % (rec, f.relative_to(up / rec)))
    step = up / "p-reels-pip" / "steps" / "04-build-background.md"
    step.write_text(step.read_text(encoding="utf-8").replace(ss._STEP_TYPING_RENDER_EDITS["04-build-background.md"][1],
                                                           "- drifted typing bullet\n"), encoding="utf-8")
    try:
        ss.apply_typing_render_usage(up / "p-reels-pip", "fixture")
        bad.append("transform did not fail on a step 04 without its anchor")
    except SystemExit:
        pass
except Exception as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi280_detail" == "ok" ]]; then
  pass "WI2.80 recipe steps name only scripts their bundle ships; step 04 names the real typing render"
else
  fail "WI2.80 recipe steps name only shipped scripts" "$wi280_detail"
fi
rm -rf "$wi280_root"

echo "=== Case 59: WI2.83 — the spotlight big-stat takeover fits its stat inside the safe width ==="
# Observed 2026-10-21 (smoke 23b, p-reels-spotlight on Render 12bd5e0): the tk-stat takeover set
# "100,000" at a fixed 340 px; it was wider than the 1080 px frame and clipped on both edges. Every
# p-reels-spotlight tk-stat.html copy now keeps the stat on one line and scales it down to <= 900 px
# (keeping 340 px when it already fits). The template's own script runs here in node with a fake
# DOM whose text width grows with font size, so the old fixed-size template fails this case.
wi283_root="$(mktemp -d)"
wi283_detail="$(python3 - "$REPO_DIR" "$wi283_root" <<'PY'
import importlib.util, json, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
SIM = r"""
const vm = require('vm'), fs = require('fs');
const [tplPath, stat, emPerChar] = process.argv.slice(2);
const src = fs.readFileSync(tplPath, 'utf8');
const scripts = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (scripts.length !== 1) { console.log(JSON.stringify({ error: 'inline scripts: ' + scripts.length })); process.exit(0); }
const code = scripts[0].replace(/\{\{ID\}\}/g, 'tk0').replace(/\{\{DURATION\}\}/g, '3');
const DESIGN = 340;  // the template's CSS size: what a page shows when no script sets one
function el(text) {
  return { textContent: text, innerHTML: text, style: {},
    get scrollWidth() { const fs = parseFloat(this.style.fontSize) || DESIGN;
      return Math.round(fs * parseFloat(emPerChar) * this.textContent.length); } };
}
const els = { '.js-stat': el(stat), '.js-label': el('VIEWS IN 90 DAYS') };
const tl = new Proxy({}, { get: () => () => tl });
let ready = null;
const ctx = { window: {}, gsap: { timeline: () => tl }, parseFloat, Math,
  document: { querySelector: s => els[Object.keys(els).find(k => s.endsWith(k))] || el(''),
              fonts: { ready: { then: f => { ready = f; } } } } };
vm.runInNewContext(code, ctx);
if (ready) ready();  // fonts finished loading: the page may refit
const s = els['.js-stat'];
console.log(JSON.stringify({ size: parseFloat(s.style.fontSize) || DESIGN, width: s.scrollWidth }));
"""
(root / "sim.js").write_text(SIM, encoding="utf-8")
def sim(tpl, stat, em):
    out = subprocess.run(["node", str(root / "sim.js"), str(tpl), stat, str(em)],
                         capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        return {"error": out.stderr.strip()[-200:]}
    return json.loads(out.stdout)
try:
    skills = repo / "skills"
    tpls = sorted(p for p in skills.rglob("tk-stat.html")
                  if p.parent.name == "templates" and p.parent.parent.name == "p-reels-spotlight")
    if len(tpls) != 2:
        bad.append("expected 2 p-reels-spotlight tk-stat.html copies, found %d" % len(tpls))
    if len({t.read_bytes() for t in tpls}) > 1:
        bad.append("the tk-stat.html copies differ")
    # 0.55 em/char ~ Oswald 700 digits ("100,000" at 340px ~ 1300px, as observed); 0.75 = wide caps.
    for tpl in tpls:
        rel = tpl.relative_to(repo)
        for stat, em in (("100,000", 0.55), ("$1,234,567.8", 0.55), ("WWWWWWWWWWWW", 0.75), ("1", 0.55)):
            r = sim(tpl, stat, em)
            if "error" in r:
                bad.append("%s: %s did not run: %s" % (rel, stat, r["error"])); continue
            if r["width"] > 900:
                bad.append("%s: %r is %dpx wide at %spx, past the 900px safe width" % (rel, stat, r["width"], r["size"]))
        r = sim(tpl, "3X", 0.55)
        if r.get("size") != 340:
            bad.append("%s: a stat that fits (3X) did not keep the 340px design size: %r" % (rel, r))
        body = tpl.read_text(encoding="utf-8")
        if not re.search(r"\.stat \{[^}]*white-space: nowrap", body):
            bad.append("%s: .stat is not kept on one line (white-space: nowrap)" % rel)
    spec = importlib.util.spec_from_file_location("ss283", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    fit = getattr(ss, "apply_spotlight_stat_fit", None)
    if fit is None:
        bad.append("sync-skills.py has no apply_spotlight_stat_fit transform")
    else:
        # Restore the old fixed-size template in a copy; the transform upgrades it once, then is a no-op,
        # and its output is byte-identical to the committed bundle.
        up = root / "skills"
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            shutil.copytree(skills / rec, up / rec)
        for t in up.rglob("tk-stat.html"):
            text = t.read_text(encoding="utf-8")
            for old, new in reversed(ss._SPOTLIGHT_STAT_EDITS):
                text = text.replace(new, old)
            t.write_text(text, encoding="utf-8")
            r = sim(t, "100,000", 0.55)
            if r.get("width", 0) <= 900:
                bad.append("sanity: the restored old template was not caught (%r)" % r)
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            n1 = fit(up / rec, rec); n2 = fit(up / rec, rec)
            if (n1, n2) != (1, 0):
                bad.append("transform on %s changed (%d, %d) file(s), expected (1, 0)" % (rec, n1, n2))
            for f in sorted(p for p in (up / rec).rglob("*") if p.is_file()):
                if f.read_bytes() != (skills / rec / f.relative_to(up / rec)).read_bytes():
                    bad.append("transform output differs from the committed %s/%s" % (rec, f.relative_to(up / rec)))
        t = up / "p-reels-spotlight" / "templates" / "tk-stat.html"
        text = t.read_text(encoding="utf-8")
        for old, new in reversed(ss._SPOTLIGHT_STAT_EDITS):
            text = text.replace(new, old)
        t.write_text(text.replace("font-size: 340px", "font-size: 300px"), encoding="utf-8")
        try:
            fit(up / "p-reels-spotlight", "fixture"); bad.append("transform did not fail on a drifted tk-stat.html")
        except SystemExit:
            pass
        t.unlink()
        try:
            fit(up / "p-reels-spotlight", "p-reels-spotlight"); bad.append("transform did not fail on a missing tk-stat.html")
        except SystemExit:
            pass
except Exception as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi283_detail" == "ok" ]]; then
  pass "WI2.83 spotlight tk-stat fits stats up to 12 characters inside the 900px safe width (every copy)"
else
  fail "WI2.83 spotlight tk-stat fits the stat inside the safe width" "$wi283_detail"
fi
rm -rf "$wi283_root"

echo "=== Case 60: WI2.85 — the spotlight big-stat slam-in starts inside the frame for a wide stat ==="
# Observed 2026-10-21 (final_checks refused a spotlight smoke on Render 137765e): WI2.83 fits the
# settled stat to <= 900 px, but the GSAP slam still started at scale 2.4, so a fitted "100,000"
# (~900 px) began ~2100 px wide and clipped both frame edges around 0.33 s. Every p-reels-spotlight
# tk-stat.html copy now starts the slam at min(2.4, 936 / fitted width) (936 = 1080 - 2x72), and
# re-reads it after the fonts refit. The template script runs in node with a fake DOM (text width
# grows with font size; a fallback font is wider until fonts load) and a fake GSAP that records the
# slam's start scale the way GSAP does: at build, and again only if the timeline is invalidated.
wi285_root="$(mktemp -d)"
wi285_detail="$(python3 - "$REPO_DIR" "$wi285_root" <<'PY'
import importlib.util, json, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
SIM = r"""
const vm = require('vm'), fs = require('fs');
const [tplPath, stat, emFallback, emLoaded] = process.argv.slice(2);
const src = fs.readFileSync(tplPath, 'utf8');
const scripts = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (scripts.length !== 1) { console.log(JSON.stringify({ error: 'inline scripts: ' + scripts.length })); process.exit(0); }
const code = scripts[0].replace(/\{\{ID\}\}/g, 'tk0').replace(/\{\{DURATION\}\}/g, '3');
let em = parseFloat(emFallback);  // the fallback font until fonts load
function el(text) {
  return { textContent: text, innerHTML: text, style: {},
    get scrollWidth() { const fs = parseFloat(this.style.fontSize) || 340;
      return Math.round(fs * em * this.textContent.length); } };
}
const els = { '.js-stat': el(stat), '.js-label': el('VIEWS IN 90 DAYS') };
const slams = [];  // fromTo tweens on the stat: GSAP records a function value when the tween inits
const tl = { invalidate() { slams.forEach(s => { s.start = undefined; }); return tl; } };
const val = v => (typeof v === 'function' ? v(0, els['.js-stat'], [els['.js-stat']]) : v);
tl.fromTo = (sel, from, to) => { if (String(sel).endsWith('.js-stat')) slams.push({ from, start: val(from.scale) }); return tl; };
tl.to = () => tl;
const readies = [];
const ctx = { window: {}, gsap: { timeline: () => tl }, parseFloat, Math,
  document: { querySelector: s => els[Object.keys(els).find(k => s.endsWith(k))] || el(''),
              fonts: { ready: { then: f => { readies.push(f); } } } } };
vm.runInNewContext(code, ctx);
em = parseFloat(emLoaded);           // fonts finished loading
readies.forEach(f => f());           // callbacks run in registration order, like a promise
const s = slams[0];
if (!s) { console.log(JSON.stringify({ error: 'no stat fromTo slam' })); process.exit(0); }
const start = s.start === undefined ? val(s.from.scale) : s.start;  // next seek re-inits if invalidated
const width = els['.js-stat'].scrollWidth;
console.log(JSON.stringify({ start, width, startWidth: Math.round(start * width) }));
"""
(root / "sim.js").write_text(SIM, encoding="utf-8")
def sim(tpl, stat, em_fallback, em_loaded):
    out = subprocess.run(["node", str(root / "sim.js"), str(tpl), stat, str(em_fallback), str(em_loaded)],
                         capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        return {"error": out.stderr.strip()[-200:]}
    return json.loads(out.stdout)
try:
    skills = repo / "skills"
    tpls = sorted(p for p in skills.rglob("tk-stat.html")
                  if p.parent.name == "templates" and p.parent.parent.name == "p-reels-spotlight")
    if len(tpls) != 2:
        bad.append("expected 2 p-reels-spotlight tk-stat.html copies, found %d" % len(tpls))
    if len({t.read_bytes() for t in tpls}) > 1:
        bad.append("the tk-stat.html copies differ")
    for tpl in tpls:
        rel = tpl.relative_to(repo)
        # (fallback em, loaded em): fonts that do not change width, a wider fallback, a narrower fallback.
        for stat in ("100,000", "$1,234,567.8", "WWWWWWWWWWWW"):
            for ems in ((0.55, 0.55), (0.70, 0.55), (0.45, 0.55)):
                r = sim(tpl, stat, *ems)
                if "error" in r:
                    bad.append("%s: %s did not run: %s" % (rel, stat, r["error"])); continue
                if r["startWidth"] > 936:
                    bad.append("%s: %r slams in %dpx wide (scale %.2f x %dpx), past the 936px padded width (fonts %s)"
                               % (rel, stat, r["startWidth"], r["start"], r["width"], ems))
        for ems in ((0.55, 0.55), (0.70, 0.55)):
            r = sim(tpl, "3X", *ems)
            if r.get("start") != 2.4:
                bad.append("%s: a short stat (3X) lost the full 2.4 slam: %r" % (rel, r))
    spec = importlib.util.spec_from_file_location("ss285", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    slam_edits = getattr(ss, "_SPOTLIGHT_SLAM_EDITS", None)
    if slam_edits is None or not all(e in ss._SPOTLIGHT_STAT_EDITS for e in slam_edits):
        bad.append("sync-skills.py apply_spotlight_stat_fit does not carry the WI2.85 slam edits")
    else:
        # From the WI2.83 (137765e) template the transform adds only the slam cap, once, and its
        # output is byte-identical to the committed bundle.
        up = root / "skills"
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            shutil.copytree(skills / rec, up / rec)
        for t in up.rglob("tk-stat.html"):
            text = t.read_text(encoding="utf-8")
            for old, new in reversed(slam_edits):
                text = text.replace(new, old)
            t.write_text(text, encoding="utf-8")
            r = sim(t, "100,000", 0.55, 0.55)
            if r.get("startWidth", 0) <= 936:
                bad.append("sanity: the restored WI2.83 template was not caught (%r)" % r)
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            n1 = ss.apply_spotlight_stat_fit(up / rec, rec); n2 = ss.apply_spotlight_stat_fit(up / rec, rec)
            if (n1, n2) != (1, 0):
                bad.append("transform on %s changed (%d, %d) file(s), expected (1, 0)" % (rec, n1, n2))
            for f in sorted(p for p in (up / rec).rglob("*") if p.is_file()):
                if f.read_bytes() != (skills / rec / f.relative_to(up / rec)).read_bytes():
                    bad.append("transform output differs from the committed %s/%s" % (rec, f.relative_to(up / rec)))
        t = up / "p-reels-spotlight" / "templates" / "tk-stat.html"
        text = t.read_text(encoding="utf-8")
        for old, new in reversed(slam_edits):
            text = text.replace(new, old)
        t.write_text(text.replace("{ scale: 2.4, opacity: 0 }", "{ scale: 2.2, opacity: 0 }"), encoding="utf-8")
        try:
            ss.apply_spotlight_stat_fit(up / "p-reels-spotlight", "fixture")
            bad.append("transform did not fail on a drifted slam tween")
        except SystemExit:
            pass
except Exception as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi285_detail" == "ok" ]]; then
  pass "WI2.85 spotlight tk-stat slam starts at min(2.4, 936 / fitted width): wide stats stay inside, 3X keeps 2.4 (every copy)"
else
  fail "WI2.85 spotlight tk-stat slam starts inside the padded frame width" "$wi285_detail"
fi
rm -rf "$wi285_root"

echo "=== Case 61: WI2.86 — the spotlight end card starts only after the last spoken word ends ==="
# Observed 2026-10-21 (re-smoke 24, p-reels-spotlight, Render 503d906): step 06 started the end card
# at bed - cta_duration (~39.0 s) while the closing line ran to 41.6 s, so it played over the card
# with no face and no captions. Every p-reels-spotlight steps/06-assemble.md copy now starts the card
# at max(bed - cta_duration, last word end) and renders it at the shorter length; under 1.0 s left
# it now fails the step with the reason (WI2.90; it used to skip the card). The section-4 bash block of each copy runs under bash with a
# stub ffmpeg/npx (the overlay window is read from the ffmpeg call) and the real cta-card.py.
wi286_root="$(mktemp -d)"
wi286_detail="$(python3 - "$REPO_DIR" "$wi286_root" <<'PY'
import importlib.util, json, os, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
STUB = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$WI286_LOG\"\nfor a; do last=$a; done\ncase \"$last\" in *.mp4|*.json) : > \"$last\";; esac\nexit 0\n"
bin_dir = root / "bin"; bin_dir.mkdir()
for tool in ("ffmpeg", "npx"):
    (bin_dir / tool).write_text(STUB); (bin_dir / tool).chmod(0o755)
def block(step):
    text = step.read_text(encoding="utf-8")
    sec = text.split("### 4. CTA end card", 1)[1].split("### 5.", 1)[0]
    m = re.search(r"```bash\n(.*?)```", sec, re.S)
    return m.group(1) if m else None
def run(step, case, bed, cta, words_end, caption_end, card="on", sh="bash"):
    work = root / case; shutil.rmtree(work, ignore_errors=True); (work / "work").mkdir(parents=True)
    words = [{"text": "built", "start": words_end - 0.4, "end": words_end - 0.2},
             {"text": "you.", "start": words_end - 0.2, "end": words_end}]
    (work / "work" / "words.json").write_text(json.dumps(words))
    plan = {"brand": {"bg": "#0F172A", "accent": "#F97316", "fg": "#F1F5F9"},
            "caption_groups": [{"start": 38.5, "end": caption_end, "words": [
                {"w": "built", "s": 38.5, "e": 39.0}, {"w": "you.", "s": 39.0, "e": caption_end}]}]}
    (work / "work" / "plan.json").write_text(json.dumps(plan))
    (work / "work" / "polished.mp4").write_bytes(b"x" * 10)
    (work / "brief.json").write_text(json.dumps({"brand": {"name": "Test", "handle": "@test", "cta": "Try it"}}))
    code = block(step)
    if code is None:
        return {"error": "no bash block in section 4"}
    (work / "s4.sh").write_text("set -u\nCTA_CARD=%s; CTA_DURATION=%s; BED_DUR=%s\nSKILL_DIR=%s\n%s"
                                % (card, cta, bed, repo / "skills" / "p-reels-spotlight", code))
    log = work / "ffmpeg.log"
    env = dict(os.environ, PATH="%s:%s" % (bin_dir, os.environ["PATH"]), WI286_LOG=str(log))
    p = subprocess.run([sh, "s4.sh"], cwd=work, env=env, capture_output=True, text=True, timeout=60)
    calls = log.read_text().splitlines() if log.exists() else []
    over = [c for c in calls if "overlay=enable" in c]
    m = re.search(r"between\(t,([0-9.]+),([0-9.]+)\)", over[0]) if over else None
    card_json = work / "work" / "cta-card.json"
    dur = json.loads(card_json.read_text())["duration"] if card_json.exists() and card_json.stat().st_size else None
    return {"rc": p.returncode, "out": (p.stdout + p.stderr)[-300:], "start": float(m.group(1)) if m else None,
            "end": float(m.group(2)) if m else None, "card_dur": dur,
            "assembled": (work / "work" / "assembled.mp4").exists()}
try:
    skills = repo / "skills"
    steps = sorted(p for p in skills.rglob("06-assemble.md")
                   if p.parent.name == "steps" and p.parent.parent.name.startswith("p-reels-spotlight"))
    if len(steps) != 3:
        bad.append("expected 3 p-reels-spotlight steps/06-assemble.md copies, found %d" % len(steps))
    if len({s.read_bytes() for s in steps}) > 1:
        bad.append("the 06-assemble.md copies differ")
    shells = ["bash"] + (["/bin/bash"] if Path("/bin/bash").exists() else [])
    for step in steps:
        rel = step.relative_to(repo)
        for sh in shells:
            # Speech to 41.6 s on a 44.0 s bed: the old rule started the card at 41.0 s, over the last words.
            r = run(step, "late", 44.0, 3.0, 41.6, 41.6, sh=sh)
            if r.get("rc") != 0 or r.get("start") is None or r["start"] < 41.6 - 1e-6 or abs(r["end"] - 44.0) > 1e-6:
                bad.append("%s (%s): card over speech, bed 44.0 / last word 41.6: %r" % (rel, sh, r))
            elif r.get("card_dur") is None or abs(float(r["card_dur"]) - 2.4) > 0.01:
                bad.append("%s (%s): card not rendered at the 2.4 s left after the last word: %r" % (rel, sh, r))
            # Plenty of tail: the card keeps its full cta_duration at the bed end.
            r = run(step, "room", 45.0, 3.0, 41.6, 41.6, sh=sh)
            if r.get("rc") != 0 or r.get("start") is None or abs(r["start"] - 42.0) > 1e-6 or abs(float(r["card_dur"] or 0) - 3.0) > 0.01:
                bad.append("%s (%s): full-length card lost when there is room: %r" % (rel, sh, r))
            # A caption word ending later than the transcript also holds the card back.
            r = run(step, "caption", 44.0, 3.0, 41.2, 41.8, sh=sh)
            if r.get("rc") != 0 or r.get("start") is None or r["start"] < 41.8 - 1e-6:
                bad.append("%s (%s): card starts before the last caption word ends: %r" % (rel, sh, r))
            # The smoke: speech runs to within 0.07 s of the bed end -> no card over the speech. Since
            # WI2.89 the bed always has a tail, so WI2.90 makes this a loud step failure, not a silent skip.
            r = run(step, "smoke", 41.67, 3.0, 41.6, 41.6, sh=sh)
            if r.get("rc") == 0 or r.get("start") is not None or r.get("assembled") or "end card: only" not in r.get("out", ""):
                bad.append("%s (%s): under 1.0 s after the last word, step 06 does not stop with the reason (WI2.90): %r" % (rel, sh, r))
            r = run(step, "off", 44.0, 3.0, 41.6, 41.6, card="off", sh=sh)
            if r.get("rc") != 0 or r.get("start") is not None or not r.get("assembled"):
                bad.append("%s (%s): cta_card off still overlays a card: %r" % (rel, sh, r))
    spec = importlib.util.spec_from_file_location("ss286", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    edits = getattr(ss, "_SPOTLIGHT_CTA_EDITS", None)
    if edits is None or not hasattr(ss, "apply_spotlight_end_card"):
        bad.append("sync-skills.py does not carry the WI2.86 apply_spotlight_end_card transform")
    else:
        # From the 503d906 step the transform adds the rule once and matches the committed bundle.
        # WI2.90 (apply_spotlight_end_card_room) runs after it on step 06, so it is reverted first and re-applied.
        room = [e for rel, _f, eds in getattr(ss, "_SPOTLIGHT_CTA_ROOM_FILES", ()) if rel == ss.SPOTLIGHT_ASSEMBLE_FILE for e in eds]
        def unroom(text):
            for old, new in reversed(room):
                text = text.replace(new, old)
            return text
        up = root / "skills"
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            shutil.copytree(skills / rec, up / rec)
        for t in up.rglob("06-assemble.md"):
            if t.parent.name != "steps" or not t.parent.parent.name.startswith("p-reels-spotlight"):
                continue
            text = unroom(t.read_text(encoding="utf-8"))
            for old, new in reversed(edits):
                text = text.replace(new, old)
            t.write_text(text, encoding="utf-8")
            r = run(t, "restored", 44.0, 3.0, 41.6, 41.6)
            if r.get("start") is None or r["start"] >= 41.6 - 1e-6:
                bad.append("sanity: the restored 503d906 step was not caught (%r)" % r)
        for rec, n in (("p-reels-spotlight", 1), ("p-reels-spotlight-heygen", 2)):
            n1 = ss.apply_spotlight_end_card(up / rec, rec); n2 = ss.apply_spotlight_end_card(up / rec, rec)
            if (n1, n2) != (n, 0):
                bad.append("transform on %s changed (%d, %d) file(s), expected (%d, 0)" % (rec, n1, n2, n))
            if room:
                ss.apply_spotlight_end_card_room(up / rec, rec)
            for f in sorted(p for p in (up / rec).rglob("*") if p.is_file()):
                if f.read_bytes() != (skills / rec / f.relative_to(up / rec)).read_bytes():
                    bad.append("transform output differs from the committed %s/%s" % (rec, f.relative_to(up / rec)))
        t = up / "p-reels-spotlight" / "steps" / "06-assemble.md"
        text = unroom(t.read_text(encoding="utf-8"))
        for old, new in reversed(edits):
            text = text.replace(new, old)
        t.write_text(text.replace("print(${BED_DUR} - ${CTA_DURATION})", "print(${BED_DUR} - ${CTA_DURATION} - 0.5)"), encoding="utf-8")
        try:
            ss.apply_spotlight_end_card(up / "p-reels-spotlight", "fixture")
            bad.append("transform did not fail on a drifted CTA_START line")
        except SystemExit:
            pass
except Exception as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi286_detail" == "ok" ]]; then
  pass "WI2.86 spotlight end card starts at max(bed - cta_duration, last word end); under 1.0 s fails the step (WI2.90, every copy)"
else
  fail "WI2.86 spotlight end card starts only after the last spoken word ends" "$wi286_detail"
fi
rm -rf "$wi286_root"

echo "=== Case 62: WI2.89 — the spotlight bed gets a silent tail so the end card always shows ==="
# Observed 2026-10-21 (re-smoke clip heygen-avatar.mp4, Render 5158704): the bed was 41.67 s and the
# speech ran to 41.6 s, so the WI2.86 step 06 rule (card after the last word, skipped under 1.0 s)
# skipped the end card and the reel shipped with no CTA. Step 01 of every p-reels-spotlight copy now
# holds the last frame with silence until cta_duration + 0.5 s follows the speech end (tail at most
# 3.5 s). Its section-4b bash block runs on real ffmpeg clips; the bed it makes then goes through the
# real step 06 section-4 block (stub ffmpeg/npx, as in Case 61) and the real transcript/plan checks.
wi289_root="$(mktemp -d)"
wi289_detail="$(python3 - "$REPO_DIR" "$wi289_root" <<'PY'
import importlib.util, json, os, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
def run(*a, **kw):
    return subprocess.run([str(x) for x in a], capture_output=True, text=True, **kw)
def dur(p, stream=None):
    args = ["ffprobe", "-v", "error"] + (["-select_streams", stream, "-show_entries", "stream=duration"] if stream
                                          else ["-show_entries", "format=duration"]) + ["-of", "csv=p=0", p]
    return float(run(*args).stdout.strip().splitlines()[0])
def trailing_silence(p):
    d, log = dur(p), run("ffmpeg", "-hide_banner", "-i", p, "-af", "silencedetect=noise=-40dB:d=0.3", "-f", "null", "-").stderr
    st = [float(x) for x in re.findall(r"silence_start: (-?[0-9.]+)", log)]
    en = [float(x) for x in re.findall(r"silence_end: (-?[0-9.]+)", log)]
    return d - st[-1] if st and (len(en) < len(st) or en[-1] >= d - 0.05) else 0.0
def clip(name, d, speech):
    # a tone stands in for the voice: it runs to `speech` s, then silence to `d` s
    path = root / "clips" / name; path.parent.mkdir(exist_ok=True)
    r = run("ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=270x480:r=30:d=%.3f" % d, "-f", "lavfi",
            "-i", "sine=f=220:d=%.3f,volume=0.5,apad=whole_dur=%.3f" % (speech, d), "-c:v", "libx264", "-preset",
            "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ar", "48000", "-ac", "2", "-t", "%.3f" % d, path)
    if r.returncode:
        raise RuntimeError("clip %s: %s" % (name, r.stderr[-200:]))
    return path
def section(step, start, stop):
    text = step.read_text(encoding="utf-8")
    if start not in text:
        return None
    m = re.search(r"```bash\n(.*?)```", text.split(start, 1)[1].split(stop, 1)[0], re.S)
    return m.group(1) if m else None
def prepare(step, case, src, card="on", cta=3.0):
    work = root / case; shutil.rmtree(work, ignore_errors=True); (work / "work").mkdir(parents=True)
    shutil.copy(src, work / "work" / "base.mp4")
    (work / "brief.json").write_text(json.dumps({"options": {"cta_card": card, "cta_duration": cta}}))
    code = section(step, "### 4b.", "### 5.")
    if code is None:
        return None
    (work / "s4b.sh").write_text("set -u\n" + code)
    p = subprocess.run(["bash", "s4b.sh"], cwd=work, capture_output=True, text=True, timeout=300)
    return {"rc": p.returncode, "out": (p.stdout + p.stderr)[-300:], "bed": work / "work" / "base.mp4"}
STUB = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$WI289_LOG\"\nfor a; do last=$a; done\ncase \"$last\" in *.mp4|*.json) : > \"$last\";; esac\nexit 0\n"
stub_bin = root / "bin"; stub_bin.mkdir()
for tool in ("ffmpeg", "npx"):
    (stub_bin / tool).write_text(STUB); (stub_bin / tool).chmod(0o755)
def assemble(step, case, bed, last_word):
    # step 06 section 4 (the WI2.86 end-card rule) on the bed step 01 made
    work = root / case; shutil.rmtree(work, ignore_errors=True); (work / "work").mkdir(parents=True)
    (work / "work" / "words.json").write_text(json.dumps([{"text": "you.", "start": last_word - 0.3, "end": last_word}]))
    (work / "work" / "plan.json").write_text(json.dumps({"brand": {"bg": "#0F172A", "accent": "#F97316", "fg": "#F1F5F9"},
        "caption_groups": [{"start": last_word - 0.3, "end": last_word, "words": [{"w": "you.", "s": last_word - 0.3, "e": last_word}]}]}))
    (work / "work" / "polished.mp4").write_bytes(b"x" * 10)
    (work / "brief.json").write_text(json.dumps({"brand": {"name": "Test", "handle": "@test", "cta": "Try it"}}))
    code = section(step.parent / "06-assemble.md", "### 4. CTA end card", "### 5.")
    (work / "s4.sh").write_text("set -u\nCTA_CARD=on; CTA_DURATION=3.0; BED_DUR=%s\nSKILL_DIR=%s\n%s"
                                % (bed, repo / "skills" / "p-reels-spotlight", code))
    log = work / "ffmpeg.log"
    env = dict(os.environ, PATH="%s:%s" % (stub_bin, os.environ["PATH"]), WI289_LOG=str(log))
    p = subprocess.run(["bash", "s4.sh"], cwd=work, env=env, capture_output=True, text=True, timeout=60)
    over = [c for c in (log.read_text().splitlines() if log.exists() else []) if "overlay=enable" in c]
    m = re.search(r"between\(t,([0-9.]+),([0-9.]+)\)", over[0]) if over else None
    card = work / "work" / "cta-card.json"
    return {"rc": p.returncode, "out": (p.stdout + p.stderr)[-200:], "start": float(m.group(1)) if m else None,
            "card_dur": json.loads(card.read_text())["duration"] if card.exists() and card.stat().st_size else None}
try:
    skills = repo / "skills"
    steps = sorted(p for p in skills.rglob("01-prepare-footage.md")
                   if p.parent.name == "steps" and p.parent.parent.name.startswith("p-reels-spotlight"))
    if len(steps) != 3:
        bad.append("expected 3 p-reels-spotlight steps/01-prepare-footage.md copies, found %d" % len(steps))
    if len({section(s, "### 4b.", "### 5.") for s in steps}) != 1:
        bad.append("the step 01 end-card tail blocks differ between copies")
    full = clip("full.mp4", 41.67, 41.67)     # the smoke: speech to the end of a 41.67 s clip
    gap = clip("gap.mp4", 8.0, 6.5)           # 1.5 s of silence already: 2.0 s more is enough
    room = clip("room.mp4", 8.0, 4.0)         # 4.0 s of silence already: left as it is
    for step in steps:
        rel = step.relative_to(repo).parent.parent
        r = prepare(step, "smoke", full)
        if r is None:
            bad.append("%s: step 01 has no section 4b end-card tail" % rel)
            r = {"rc": 0, "bed": root / "clips" / "full.mp4"}   # the old bare bed, for the end-to-end proof
        elif r["rc"] != 0:
            bad.append("%s: tail block failed: %r" % (rel, r)); continue
        bed = dur(r["bed"])
        if not (41.67 + 3.4 <= bed <= 41.67 + 3.6) or trailing_silence(r["bed"]) < 3.3:
            bad.append("%s: speech to the end of 41.67 s: bed %.2f s, %.2f s silent tail (want ~45.17, >= 3.3)"
                       % (rel, bed, trailing_silence(r["bed"])))
        elif dur(r["bed"], "v:0") < bed - 0.1:
            bad.append("%s: the picture stops before the bed ends (last frame not held)" % rel)
        a = assemble(step, "assemble", bed, 41.6)
        if a["rc"] != 0 or a["start"] is None or a["start"] < 41.6 - 1e-6 or abs(float(a["card_dur"] or 0) - 3.0) > 0.02:
            bad.append("%s: speech to 41.6 s on the 41.67 s clip: no full 3.0 s end card after the last word: %r" % (rel, a))
        r = prepare(step, "gap", gap)
        if r and (r["rc"] != 0 or abs(dur(r["bed"]) - 10.0) > 0.1):
            bad.append("%s: 1.5 s of trailing silence should get a 2.0 s tail (bed 10.0 s): %r" % (rel, r))
        for case, src, card in (("room", room, "on"), ("off", full, "off")):
            r = prepare(step, case, src, card=card)
            if r and (r["rc"] != 0 or r["bed"].read_bytes() != src.read_bytes()):
                bad.append("%s: %s: the bed must be left as it is: %r" % (rel, case, r))
    # The checks follow the longer bed: the right transcript/plan pass, a short one still fails.
    spec = importlib.util.spec_from_file_location("ck289", repo / "bin" / "cfw-render-checks.py")
    ck = importlib.util.module_from_spec(spec); spec.loader.exec_module(ck)
    recipe = skills / "p-reels-spotlight"
    acc = json.loads((recipe / "acceptance.json").read_text())
    hub_acc = skills / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight" / "acceptance.json"
    if hub_acc.read_bytes() != (recipe / "acceptance.json").read_bytes():
        bad.append("the two acceptance.json copies differ")
    bed_path = root / "smoke" / "work" / "base.mp4"
    work = (root / "checks").resolve(); (work / "prior").mkdir(parents=True); (work / "saves").mkdir()   # no linked /var
    shutil.copy(bed_path, work / "prior" / "voice_track.mp4")
    bed = dur(work / "prior" / "voice_track.mp4")
    def verdict(fn):
        try:
            fn(); return "pass"
        except BaseException as exc:
            return "fail: %s" % exc
    tk = [{"start": 5.0, "end": 9.0, "template": "tk-stat", "fill": {"stat": "3X"}},
          {"start": 15.0, "end": 19.0, "template": "tk-quote", "fill": {"quote": "q"}}]
    for last, want in ((41.6, "pass"), (37.0, "fail")):
        (work / "saves" / "transcripts.json").write_text(json.dumps({"words": [
            {"text": "hello", "start": 0.5, "end": 1.0}, {"text": "you.", "start": last - 0.3, "end": last}]}))
        s = ck.Spotlight(recipe, work, "transcribe")
        got = verdict(lambda: s.words(acc["steps"]["transcribe"]["checks"][0]))
        if not got.startswith(want):
            bad.append("transcript ending %.1f s on a %.2f s bed: %s (want %s)" % (last, bed, got, want))
        (work / "saves" / "edit_plan.json").write_text(json.dumps({"duration": bed, "cover_at": 12.0, "takeovers": tk,
            "brand": {"bg": "#0F172A", "accent": "#F97316", "fg": "#F1F5F9"},
            "caption_groups": [{"start": 0.5, "end": last, "words": [{"w": "hello", "s": 0.5, "e": 1.0}, {"w": "you.", "s": last - 0.3, "e": last}]}]}))
        s = ck.Spotlight(recipe, work, "plan_edit")
        got = verdict(lambda: s.plan_guard(acc["steps"]["plan_edit"]["checks"][0]))
        if not got.startswith(want):
            bad.append("captions ending %.1f s on a %.2f s bed: %s (want %s)" % (last, bed, got, want))
    m = re.search(r"require\(20 <= duration\(self\.artifact\(\)\) <= ([0-9.]+)", (repo / "bin" / "cfw-render-checks.py").read_text())
    if not m or float(m.group(1)) < 60 + 3.5:
        bad.append("the prepare_footage bed limit does not allow 60 s of speech + the 3.5 s tail")
    win = next(c for c in acc["checks"] if c["id"] == "duration_window")
    if win["max_s"] < 60 + 3.5 + 0.4:
        bad.append("duration_window max_s %s does not allow 60 s + 3.5 s tail + 0.4 s cover" % win["max_s"])
    for p in sorted(skills.rglob("03-plan-edit.md")):
        if p.parent.parent.name.startswith("p-reels-spotlight") and "- dur) < 4.5, \"captions do not cover the bed\"" not in p.read_text():
            bad.append("%s: the step 03 caption guard does not allow the tail" % p.relative_to(repo))
    for p in (recipe / "SKILL.md", skills / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight" / "SKILL.md"):
        t = p.read_text(encoding="utf-8")
        if "overlaying the final 2.5–3s" in t or 'CTA_START=$(python3 -c "print(${BED_DUR} - ${CTA_DURATION})")' in t \
                or "End-card tail (WI2.89" not in t:
            bad.append("%s still describes the card over the final seconds of the bare bed" % p.relative_to(repo))
    finals = sorted(p for p in skills.rglob("07-final-checks.md") if p.parent.parent.name.startswith("p-reels-spotlight"))
    if len({p.read_bytes() for p in finals}) != 1 or any("silent tail" not in p.read_text() for p in finals):
        bad.append("07-final-checks.md copies differ or do not describe the end card after the last word")
    # sync-skills.py keeps every copy in line.
    spec = importlib.util.spec_from_file_location("ss289", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    files = getattr(ss, "_SPOTLIGHT_TAIL_FILES", None)
    if files is None or not hasattr(ss, "apply_spotlight_bed_tail"):
        bad.append("sync-skills.py does not carry the WI2.89 apply_spotlight_bed_tail transform")
    else:
        up = root / "skills"
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            shutil.copytree(skills / rec, up / rec)
        def revert(base):
            for rel, full_only, edits in files:
                if full_only and base.name != "p-reels-spotlight":
                    continue
                t = (base / rel).read_text(encoding="utf-8")
                for old, new in reversed(edits):
                    t = t.replace(new, old)
                (base / rel).write_text(t, encoding="utf-8")
        for base in (up / "p-reels-spotlight", up / "p-reels-spotlight-heygen",
                     up / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight"):
            revert(base)
        for rec, n in (("p-reels-spotlight", 7), ("p-reels-spotlight-heygen", 12)):
            n1 = ss.apply_spotlight_bed_tail(up / rec, rec); n2 = ss.apply_spotlight_bed_tail(up / rec, rec)
            if (n1, n2) != (n, 0):
                bad.append("transform on %s changed (%d, %d) file(s), expected (%d, 0)" % (rec, n1, n2, n))
            for f in sorted(p for p in (up / rec).rglob("*") if p.is_file()):
                if f.read_bytes() != (skills / rec / f.relative_to(up / rec)).read_bytes():
                    bad.append("transform output differs from the committed %s/%s" % (rec, f.relative_to(up / rec)))
        revert(up / "p-reels-spotlight")
        t = up / "p-reels-spotlight" / "steps" / "01-prepare-footage.md"
        t.write_text(t.read_text(encoding="utf-8").replace("### 5. Seal and save\n", "### 5. Seal it\n"), encoding="utf-8")
        try:
            ss.apply_spotlight_bed_tail(up / "p-reels-spotlight", "fixture")
            bad.append("transform did not fail on a drifted step 01 anchor")
        except SystemExit:
            pass
except Exception as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad))
PY
)"
if [[ "$wi289_detail" == "ok" ]]; then
  pass "WI2.89 spotlight bed gets a silent tail (cta_duration + 0.5 s, <= 3.5 s): full end card after the last word (every copy)"
else
  fail "WI2.89 spotlight bed gets a silent tail so the end card always shows" "$wi289_detail"
fi
rm -rf "$wi289_root"

echo "=== Case 63: WI2.87 — the spotlight typing takeover is a real sub-composition, so takeovers animate ==="
# Observed 2026-10-21 (re-smoke 24, order R-VW59, Render 503d906): all four spotlight takeovers hard-cut
# to their final layout (no stat slam-in, no typing). Step 05 stripped the <template> wrapper from
# c-typing-ui's typing-scene.html and left its composition id "typing-scene" while the root slot loads
# it as data-composition-src with id "tk<i>". HyperFrames 0.7.5 never got ready ("Composition has zero
# duration. Runtime ready: false"), the render failed, and the still-card fallback composited every
# takeover as a static PNG. This case runs the real step 05 Part B assembler of every copy on a plan
# with a stat and two typing takeovers, checks each typing file is a <template> slotted under its own
# id, then runs both typing scripts in one shared page (fake DOM + GSAP) to prove each types its own
# prompt; the SKILL.md Step 5 copies and the sync transform (idempotent, fail-fast) are checked too.
wi287_root="$(mktemp -d)"
wi287_detail="$(python3 - "$REPO_DIR" "$wi287_root" <<'PY'
import importlib.util, json, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
SIM = r"""
const vm = require('vm'), fs = require('fs');
const files = process.argv.slice(2);
const els = {};
function el(id) { return els[id] || (els[id] = { id, textContent: '', style: {}, classList: { add() {} } }); }
const decode = s => s.replace(/&#10;/g, '\n').replace(/&quot;/g, '"').replace(/&#x27;/g, "'")
                     .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
const tweens = [];
function timeline() { const tl = { to(t, v) { tweens.push({ tl, t, v }); return tl; }, fromTo() { return tl; } }; return tl; }
const document = { getElementById: el, querySelector: () => null,
  createElement: () => { const o = { value: '' }; Object.defineProperty(o, 'innerHTML', { set(s) { o.value = decode(s); } }); return o; } };
const ctx = vm.createContext({ window: {}, document, gsap: { timeline }, parseFloat, Math });
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  const inline = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  if (inline.length !== 1) { console.log(JSON.stringify({ error: f + ': inline scripts ' + inline.length })); process.exit(0); }
  vm.runInContext(inline[0], ctx);
}
// Seek every typing tween to its end, the way the render's last frame does.
for (const tw of tweens) if (tw.v && typeof tw.v.onUpdate === 'function') { tw.t.n = tw.v.n; tw.v.onUpdate(); }
const typed = {};
for (const id of Object.keys(els)) if (/-ts-typed$/.test(id)) typed[id] = els[id].textContent;
console.log(JSON.stringify({ timelines: Object.keys(ctx.window.__timelines || {}), typed }));
"""
(root / "sim.js").write_text(SIM, encoding="utf-8")
def part_b(step):
    m = re.search(r'^python3 - work "\$SKILL_DIR" "\$TYPING_DIR" <<\'PY\'\n(.*?)^PY$', step.read_text(encoding="utf-8"), re.S | re.M)
    return m.group(1) if m else None
PROMPTS = ['What\'s "happening" this week?', "Plan my posts\nfor Friday"]
plan = {"duration": 12.0, "brand": {"bg": "#111111", "accent": "#3B82F6", "fg": "#F4F4F4"}, "takeovers": [
    {"start": 1.0, "end": 3.5, "template": "tk-stat", "fill": {"EYEBROW": "A month", "STAT": "45", "LABEL": "posts"}},
    {"start": 4.0, "end": 7.5, "template": "tk-typing-ui",
     "fill": {"LABEL": "CFW", "PROMPT": PROMPTS[0], "TYPING_SPEED": 0.8, "BOTTOM_TAG": "Once a week"}},
    {"start": 8.0, "end": 11.0, "template": "tk-typing-ui", "fill": {"LABEL": "CFW", "PROMPT": PROMPTS[1]}}]}
try:
    skills = repo / "skills"
    roots = [skills / "p-reels-spotlight", skills / "p-reels-spotlight-heygen",
             skills / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight"]
    for r in roots:
        step = r / "steps" / "05-render-scenes.md"
        rel = step.relative_to(repo)
        code = part_b(step)
        if code is None:
            bad.append("%s: no step 05 Part B assembler block" % rel); continue
        # Every copy's step names SKILL_DIR="$CFW_RENDER_SKILLS_DIR/p-reels-spotlight", TYPING_DIR under its .hub.
        skill = skills / "p-reels-spotlight"
        typing = skill / ".hub" / "c-typing-ui"
        w = root / ("w-" + r.name + ("-hub" if r.parent.name == ".hub" else ""))
        w.mkdir()
        (w / "plan.json").write_text(json.dumps(plan), encoding="utf-8")
        (w / "base.mp4").write_bytes(b"")
        (root / "partb.py").write_text(code, encoding="utf-8")
        out = subprocess.run([sys.executable, str(root / "partb.py"), str(w), str(skill), str(typing)],
                             capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            bad.append("%s: assembler failed: %s" % (rel, out.stderr.strip()[-200:])); continue
        index = (w / "comp" / "index.html").read_text(encoding="utf-8")
        typing_files = []
        for i, tk in enumerate(plan["takeovers"]):
            f = w / "comp" / "compositions" / ("tk%d.html" % i)
            text = f.read_text(encoding="utf-8")
            if ('data-composition-id="tk%d" data-composition-src="compositions/tk%d.html"' % (i, i)) not in index:
                bad.append("%s: root slot for tk%d missing" % (rel, i))
            if not text.lstrip().startswith('<template id="tk%d-template">' % i) or not text.rstrip().endswith("</template>"):
                bad.append("%s: tk%d (%s) is not a <template id=\"tk%d-template\"> file (stripped wrapper)"
                           % (rel, i, tk["template"], i))
            if not re.search(r'<div\s+(id="tk%d"\s+)?data-composition-id="tk%d"' % (i, i), text):
                bad.append("%s: tk%d's root element does not carry the slot id tk%d" % (rel, i, i))
            if '__timelines["tk%d"]' % i not in text:
                bad.append("%s: tk%d does not register window.__timelines[\"tk%d\"]" % (rel, i, i))
            if "typing-scene" in text:
                bad.append("%s: tk%d still names the composition \"typing-scene\"" % (rel, i))
            if "##" in text or re.search(r"\{\{[A-Z_]+\}\}", text):
                bad.append("%s: tk%d has a doubled '#' or an unfilled {{KEY}}" % (rel, i))
            if tk["template"] == "tk-typing-ui":
                typing_files.append((i, f))
        if len(typing_files) == 2 and not bad:
            sim = subprocess.run(["node", str(root / "sim.js")] + [str(f) for _, f in typing_files],
                                 capture_output=True, text=True, timeout=60)
            r_ = json.loads(sim.stdout) if sim.returncode == 0 and sim.stdout.strip() else {"error": sim.stderr[-200:]}
            if "error" in r_:
                bad.append("%s: typing scripts did not run: %s" % (rel, r_["error"]))
            else:
                for (i, _), prompt in zip(typing_files, PROMPTS):
                    got = r_["typed"].get("tk%d-ts-typed" % i)
                    if got != prompt:
                        bad.append("%s: tk%d typed %r, expected its own prompt %r" % (rel, i, got, prompt))
                    if "tk%d" % i not in r_["timelines"]:
                        bad.append("%s: timeline tk%d not registered (%r)" % (rel, i, r_["timelines"]))
    for doc in (skills / "p-reels-spotlight" / "SKILL.md",
                skills / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight" / "SKILL.md"):
        text = doc.read_text(encoding="utf-8")
        if "re_mod.sub(r'<template" in text or 'tpl_src.index(\'<template id="typing-scene-template">\')' not in text:
            bad.append("%s: Step 5 still strips the typing <template> wrapper" % doc.relative_to(repo))
    spec = importlib.util.spec_from_file_location("ss287", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    fn = getattr(ss, "apply_spotlight_typing_takeover", None)
    if fn is None:
        bad.append("sync-skills.py has no apply_spotlight_typing_takeover (WI2.87)")
    else:
        # From the pre-fix (32549b7) text the transform makes the committed bundle, once.
        up = root / "skills"
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            shutil.copytree(skills / rec, up / rec)
        # WI2.91 rewrites lines WI2.87 wrote (prompt fill, label): revert it first, re-apply it after.
        wi291 = [e for _rel, _full, edits in getattr(ss, "_SPOTLIGHT_PROMPT_FILES", ()) for e in edits]
        for f in list(up.rglob("05-render-scenes.md")) + list(up.rglob("SKILL.md")):
            text = f.read_text(encoding="utf-8")
            for old, new in reversed(wi291):
                text = text.replace(new, old)
            for old, new in ss._SPOTLIGHT_TYPING_EDITS_STEP + ss._SPOTLIGHT_TYPING_EDITS_SKILL:
                text = text.replace(new, old)
            f.write_text(text, encoding="utf-8")
        for rec, want in (("p-reels-spotlight", (2, 0)), ("p-reels-spotlight-heygen", (3, 0))):
            got = (fn(up / rec, rec), fn(up / rec, rec))
            if got != want:
                bad.append("transform on %s changed %r file(s), expected %r" % (rec, got, want))
            if wi291:
                ss.apply_spotlight_typing_prompt(up / rec, rec)
            for f in sorted(p for p in (up / rec).rglob("*") if p.is_file()):
                if f.read_bytes() != (skills / rec / f.relative_to(up / rec)).read_bytes():
                    bad.append("transform output differs from the committed %s/%s" % (rec, f.relative_to(up / rec)))
        step = up / "p-reels-spotlight" / "steps" / "05-render-scenes.md"
        text = step.read_text(encoding="utf-8")
        for old, new in ss._SPOTLIGHT_TYPING_EDITS_STEP:
            text = text.replace(new, old)
        step.write_text(text.replace("src = re.sub(r'<template[^>]*>\\s*', '', src)", "src = src.strip()"), encoding="utf-8")
        try:
            fn(up / "p-reels-spotlight", "fixture")
            bad.append("transform did not fail on a drifted step 05 anchor")
        except SystemExit:
            pass
except (Exception, SystemExit) as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad[:12]))
PY
)"
if [[ "$wi287_detail" == "ok" ]]; then
  pass "WI2.87 spotlight typing takeover keeps its <template> and the slot id tk<i>, scoped per slot, so HyperFrames renders every takeover's motion (every copy)"
else
  fail "WI2.87 spotlight typing takeover is a real sub-composition" "$wi287_detail"
fi
rm -rf "$wi287_root"

echo "=== Case 64: WI2.93 — the spotlight end card renders through hyperframes from a project dir, or the step fails ==="
# Observed 2026-10-21 (smoke 25, p-reels-spotlight, Render 69bc5ce): the end card (42.6-45.6 s) was
# completely still. Step 06 ran `npx hyperframes@0.7.5 render work/cta-card.json`; hyperframes 0.7.5
# `render` takes a project DIRECTORY holding index.html, so it stopped with "Not a directory" and the
# step's ffmpeg drawtext fallback made a still card ("CTA fallback rendered", assemble.log). Every
# p-reels-spotlight step 06 copy now has cta-card.py write work/cta-card/ (index.html + gsap.min.js,
# an animated composition), renders that directory and has no still fallback: a failed render exits
# non-zero. The section-4 bash block of each copy runs under bash with a stub ffmpeg and a stub npx
# that refuses a non-directory exactly as hyperframes 0.7.5 does; the SKILL.md Step 8 copies,
# cta-card.py copies and the sync transform (idempotent, fail-fast) are checked too.
wi293_root="$(mktemp -d)"
wi293_detail="$(python3 - "$REPO_DIR" "$wi293_root" <<'PY'
import importlib.util, json, os, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
FF = "#!/bin/sh\nprintf 'ffmpeg %s\\n' \"$*\" >> \"$WI293_LOG\"\nfor a; do last=$a; done\ncase \"$last\" in *.mp4) : > \"$last\";; esac\nexit 0\n"
# npx hyperframes@0.7.5 render <dir> ...: like resolveProjectOrThrow() in hyperframes 0.7.5.
NPX = ("#!/bin/sh\nprintf 'npx %s\\n' \"$*\" >> \"$WI293_LOG\"\n[ \"$2\" = render ] || exit 0\n"
       "if [ ! -d \"$3\" ]; then echo \"Not a directory: $3\" >&2; exit 1; fi\n"
       "if [ ! -f \"$3/index.html\" ]; then echo \"No composition found in $3\" >&2; exit 1; fi\n"
       "if [ -n \"${WI293_FAIL:-}\" ]; then echo 'Composition has zero duration (stub)' >&2; exit 1; fi\n"
       "for a; do last=$a; done\n: > \"$last\"\nexit 0\n")
bin_dir = root / "bin"; bin_dir.mkdir()
for tool, body in (("ffmpeg", FF), ("npx", NPX)):
    (bin_dir / tool).write_text(body); (bin_dir / tool).chmod(0o755)
def block(step):
    sec = step.read_text(encoding="utf-8").split("### 4. CTA end card", 1)[1].split("### 5.", 1)[0]
    m = re.search(r"```bash\n(.*?)```", sec, re.S)
    return m.group(1) if m else None
def run(step, case, fail_render=False):
    work = root / case; shutil.rmtree(work, ignore_errors=True); (work / "work").mkdir(parents=True)
    (work / "work" / "words.json").write_text(json.dumps([{"text": "you.", "start": 41.3, "end": 41.6}]))
    (work / "work" / "plan.json").write_text(json.dumps({"brand": {"bg": "#0F172A", "accent": "#F97316", "fg": "#F1F5F9"},
        "caption_groups": [{"start": 41.3, "end": 41.6, "words": [{"w": "you.", "s": 41.3, "e": 41.6}]}]}))
    (work / "work" / "polished.mp4").write_bytes(b"x" * 10)
    (work / "brief.json").write_text(json.dumps({"brand": {"name": "Test Brand", "handle": "@test", "cta": "Follow Test Brand"}}))
    code = block(step)
    if code is None:
        return {"error": "no bash block in section 4"}
    (work / "s4.sh").write_text("set -u\nCTA_CARD=on; CTA_DURATION=3.0; BED_DUR=45.0\nSKILL_DIR=%s\n%s"
                                % (repo / "skills" / "p-reels-spotlight", code))
    log = work / "calls.log"
    env = dict(os.environ, PATH="%s:%s" % (bin_dir, os.environ["PATH"]), WI293_LOG=str(log))
    env.pop("WI293_FAIL", None)
    if fail_render:
        env["WI293_FAIL"] = "1"
    p = subprocess.run(["bash", "s4.sh"], cwd=work, env=env, capture_output=True, text=True, timeout=60)
    calls = log.read_text().splitlines() if log.exists() else []
    renders = [c.split()[3] for c in calls if c.startswith("npx ") and len(c.split()) > 3 and c.split()[2] == "render"]
    return {"rc": p.returncode, "out": (p.stdout + p.stderr)[-300:], "work": work, "renders": renders,
            "still": [c for c in calls if c.startswith("ffmpeg ") and ("color=c=" in c or "drawtext" in c)],
            "overlay": [c for c in calls if "overlay=enable" in c]}
try:
    skills = repo / "skills"
    steps = sorted(p for p in skills.rglob("06-assemble.md")
                   if p.parent.name == "steps" and p.parent.parent.name.startswith("p-reels-spotlight"))
    if len(steps) != 3:
        bad.append("expected 3 p-reels-spotlight steps/06-assemble.md copies, found %d" % len(steps))
    if len({s.read_bytes() for s in steps}) > 1:
        bad.append("the 06-assemble.md copies differ")
    for step in steps:
        rel = step.relative_to(repo)
        code = block(step) or ""
        if "cta-card.json --output" in code or "drawtext=" in code:
            bad.append("%s: section 4 still renders the .json spec or keeps a drawtext still card" % rel)
        r = run(step, "ok")
        if "error" in r:
            bad.append("%s: %s" % (rel, r["error"])); continue
        if r["rc"] != 0 or not r["renders"] or r["still"] or not r["overlay"]:
            bad.append("%s: hyperframes end-card render did not go through (rc %s, renders %r, still card %r, overlay %d): %s"
                       % (rel, r["rc"], r["renders"], r["still"][:1], len(r["overlay"]), r["out"]))
        else:
            proj = r["work"] / r["renders"][0]
            index = (proj / "index.html").read_text(encoding="utf-8") if (proj / "index.html").is_file() else ""
            m = re.search(r'data-composition-id="cta-card"[^>]*data-duration="([0-9.]+)"', index, re.S)
            if not m or abs(float(m.group(1)) - 3.0) > 0.01:
                bad.append("%s: work/cta-card/index.html has no 3.0 s cta-card composition" % rel)
            if '__timelines["cta-card"]' not in index or "tl.fromTo(\"#cta-card .card\"" not in index \
                    or 'class="word"' not in index or "Test Brand".upper() not in index:
                bad.append("%s: the end-card composition has no timeline, entry pop, words or kicker" % rel)
            if not (proj / "gsap.min.js").is_file() or "cdn" in index.lower():
                bad.append("%s: gsap.min.js not vendored into the end-card project" % rel)
        r = run(step, "fail", fail_render=True)
        if r.get("rc") == 0 or r.get("still") or r.get("overlay") or "end card" not in r.get("out", ""):
            bad.append("%s: a failed hyperframes end-card render did not stop the step loudly (rc %s, still card %r): %s"
                       % (rel, r.get("rc"), (r.get("still") or [])[:1], r.get("out")))
    ctas = [skills / "p-reels-spotlight" / "scripts" / "cta-card.py",
            skills / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight" / "scripts" / "cta-card.py"]
    if len({p.read_bytes() for p in ctas}) != 1:
        bad.append("the cta-card.py copies differ")
    for doc in (skills / "p-reels-spotlight" / "SKILL.md",
                skills / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight" / "SKILL.md"):
        t = doc.read_text(encoding="utf-8")
        s8 = t.split("### Step 8", 1)[1].split("\n### ", 1)[0] if "### Step 8" in t else ""
        if 'render "$W/cta-card.json"' in s8 or "drawtext=" in s8 or 'render "$W/cta-card" ' not in s8:
            bad.append("%s: Step 8 still renders the .json spec or keeps the drawtext still card" % doc.relative_to(repo))
    spec = importlib.util.spec_from_file_location("ss293", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    fn, files = getattr(ss, "apply_spotlight_end_card_render", None), getattr(ss, "_SPOTLIGHT_CTA_HF_FILES", None)
    if fn is None or files is None:
        bad.append("sync-skills.py has no apply_spotlight_end_card_render (WI2.93)")
    else:
        up = root / "skills"
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            shutil.copytree(skills / rec, up / rec)
        def revert(base):
            for rel, full_only, edits in files:
                if full_only and base.name != "p-reels-spotlight":
                    continue
                t = (base / rel).read_text(encoding="utf-8")
                for old, new in reversed(edits):
                    t = t.replace(new, old)
                (base / rel).write_text(t, encoding="utf-8")
        for base in (up / "p-reels-spotlight", up / "p-reels-spotlight-heygen",
                     up / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight"):
            revert(base)
        r = run(up / "p-reels-spotlight" / "steps" / "06-assemble.md", "restored")
        if r.get("rc") == 0 and not r.get("still"):
            bad.append("sanity: the restored 69bc5ce step was not caught (%r)" % {k: r.get(k) for k in ("rc", "renders")})
        for rec, want in (("p-reels-spotlight", (3, 0)), ("p-reels-spotlight-heygen", (4, 0))):
            got = (fn(up / rec, rec), fn(up / rec, rec))
            if got != want:
                bad.append("transform on %s changed %r file(s), expected %r" % (rec, got, want))
            for f in sorted(p for p in (up / rec).rglob("*") if p.is_file()):
                if f.read_bytes() != (skills / rec / f.relative_to(up / rec)).read_bytes():
                    bad.append("transform output differs from the committed %s/%s" % (rec, f.relative_to(up / rec)))
        revert(up / "p-reels-spotlight")
        t = up / "p-reels-spotlight" / "steps" / "06-assemble.md"
        t.write_text(t.read_text(encoding="utf-8").replace("work/cta-card.json --output work/cta-card.mp4",
                                                           "work/cta-card.json -o work/cta-card.mp4"), encoding="utf-8")
        try:
            fn(up / "p-reels-spotlight", "fixture")
            bad.append("transform did not fail on a drifted step 06 anchor")
        except SystemExit:
            pass
except (Exception, SystemExit) as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad[:12]))
PY
)"
if [[ "$wi293_detail" == "ok" ]]; then
  pass "WI2.93 spotlight end card renders through hyperframes from work/cta-card/ (index.html + gsap), and a failed render fails the step (every copy)"
else
  fail "WI2.93 spotlight end card renders through hyperframes or fails loudly" "$wi293_detail"
fi
rm -rf "$wi293_root"

echo "=== Case 65: WI2.92 — a failed spotlight takeover render fails step 05 loudly, with no still-card fallback ==="
# Observed 2026-10-21 (WI2.87, p-reels-spotlight): the HyperFrames takeover render failed outright
# ("Composition has zero duration. Runtime ready: false"), step 05's fallback swapped the takeovers for
# static PNG / ffmpeg-overlay cards, the step passed and the reel still reached Reviews. Every
# p-reels-spotlight step 05 copy now runs the render in its Part C block and a failed render exits
# non-zero with the hyperframes error; the still-card fallback text, the SKILL.md Fallback assembly
# section and the delivery gate's fallback pass are gone. Part C runs under bash with a stub npx that
# fails like hyperframes 0.7.5 did and a stub ffprobe; the sync transform (idempotent, fail-fast) is checked too.
wi292_root="$(mktemp -d)"
wi292_detail="$(python3 - "$REPO_DIR" "$wi292_root" <<'PY'
import importlib.util, json, os, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
HF_ERR = "Composition has zero duration. Runtime ready: false"
NPX = ("#!/bin/sh\nprintf 'npx %s\\n' \"$*\" >> \"$WI292_LOG\"\n[ \"$2\" = render ] || exit 0\n"
       "if [ -n \"${WI292_FAIL:-}\" ]; then echo 'Error: " + HF_ERR + "' >&2; exit 1; fi\n"
       "out=; prev=; for a; do [ \"$prev\" = --output ] && out=$a; prev=$a; done\n"
       "[ -n \"$out\" ] && printf 'video' > \"$out\"\nexit 0\n")
FFPROBE = ("#!/bin/sh\ncase \"$*\" in *json*) echo '{\"streams\":[{\"width\":1080,\"height\":1920}],\"format\":{\"duration\":\"30.0\"}}';;\n"
           "*) echo '1080,1920,30.0';; esac\nexit 0\n")
bin_dir = root / "bin"; bin_dir.mkdir()
for tool, body in (("npx", NPX), ("ffprobe", FFPROBE)):
    (bin_dir / tool).write_text(body); (bin_dir / tool).chmod(0o755)
def block(step):
    t = step.read_text(encoding="utf-8")
    if "### Part C" not in t:
        return None
    sec = t.split("### Part C", 1)[1].split("### Part D", 1)[0]
    m = re.search(r"```bash\n(.*?)```", sec, re.S)
    return m.group(1) if m else None
def run(step, case, fail_render=False):
    work = root / case; shutil.rmtree(work, ignore_errors=True); (work / "work" / "comp").mkdir(parents=True)
    (work / "work" / "plan.json").write_text(json.dumps({"duration": 30.0, "takeovers": [
        {"start": 3.0, "end": 7.0, "template": "tk-stat", "fill": {}}]}))
    code = block(step)
    if code is None:
        return {"error": "no bash block in Part C"}
    (work / "c.sh").write_text("set -u\n" + code)
    log = work / "calls.log"
    env = dict(os.environ, PATH="%s:%s" % (bin_dir, os.environ["PATH"]), WI292_LOG=str(log))
    env.pop("WI292_FAIL", None)
    if fail_render:
        env["WI292_FAIL"] = "1"
    p = subprocess.run(["bash", "c.sh"], cwd=work, env=env, capture_output=True, text=True, timeout=60)
    calls = log.read_text().splitlines() if log.exists() else []
    return {"rc": p.returncode, "out": (p.stdout + p.stderr)[-400:],
            "renders": [c for c in calls if c.startswith("npx ") and " render " in c]}
try:
    skills = repo / "skills"
    steps = sorted(p for p in skills.rglob("05-render-scenes.md")
                   if p.parent.name == "steps" and p.parent.parent.name.startswith("p-reels-spotlight"))
    if len(steps) != 3:
        bad.append("expected 3 p-reels-spotlight steps/05-render-scenes.md copies, found %d" % len(steps))
    if len({s.read_bytes() for s in steps}) > 1:
        bad.append("the 05-render-scenes.md copies differ")
    for step in steps:
        rel = step.relative_to(repo)
        t = step.read_text(encoding="utf-8")
        if "PNG renders of the filled templates," in t or "even after the fallback" in t:
            bad.append("%s: step 05 still offers the still-card (PNG / ffmpeg overlay) fallback" % rel)
        r = run(step, "fail", fail_render=True)
        if "error" in r:
            bad.append("%s: %s" % (rel, r["error"])); continue
        if r["rc"] == 0 or "takeovers: hyperframes render" not in r["out"] or HF_ERR not in r["out"]:
            bad.append("%s: a failed hyperframes takeover render did not stop step 05 loudly with its error "
                       "(rc %s, renders %d): %s" % (rel, r["rc"], len(r["renders"]), r["out"]))
        r = run(step, "ok")
        if r.get("rc") != 0 or not r.get("renders") or "[gate-stamp] hyperframes" not in r.get("out", ""):
            bad.append("%s: a good takeover render did not pass Part C (rc %s, renders %d): %s"
                       % (rel, r.get("rc"), len(r.get("renders") or []), r.get("out")))
    for doc in (skills / "p-reels-spotlight" / "SKILL.md",
                skills / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight" / "SKILL.md"):
        t = doc.read_text(encoding="utf-8")
        if "## Fallback assembly" in t or 'len(hf.get("reason", "")) <= 25' in t \
                or "takeovers: hyperframes render of $W/comp failed" not in t:
            bad.append("%s: SKILL.md still keeps the takeover fallback (section, gate pass) or has no loud failure"
                       % doc.relative_to(repo))
    spec = importlib.util.spec_from_file_location("ss292", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    fn, files = getattr(ss, "apply_spotlight_takeover_render_fail_loud", None), getattr(ss, "_SPOTLIGHT_TK_FILES", None)
    if fn is None or files is None:
        bad.append("sync-skills.py has no apply_spotlight_takeover_render_fail_loud (WI2.92)")
    else:
        up = root / "skills"
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            shutil.copytree(skills / rec, up / rec)
        def revert(base):
            for rel, full_only, edits in files:
                if full_only and base.name != "p-reels-spotlight":
                    continue
                t = (base / rel).read_text(encoding="utf-8")
                for old, new in reversed(edits):
                    t = t.replace(new, old)
                (base / rel).write_text(t, encoding="utf-8")
        for base in (up / "p-reels-spotlight", up / "p-reels-spotlight-heygen",
                     up / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight"):
            revert(base)
        r = run(up / "p-reels-spotlight" / "steps" / "05-render-scenes.md", "restored", fail_render=True)
        if r.get("rc") != 0:
            bad.append("sanity: the restored 20dca83 step 05 did not pass silently (%r)" % {k: r.get(k) for k in ("rc", "out")})
        for rec, want in (("p-reels-spotlight", (2, 0)), ("p-reels-spotlight-heygen", (3, 0))):
            got = (fn(up / rec, rec), fn(up / rec, rec))
            if got != want:
                bad.append("transform on %s changed %r file(s), expected %r" % (rec, got, want))
            for f in sorted(p for p in (up / rec).rglob("*") if p.is_file()):
                if f.read_bytes() != (skills / rec / f.relative_to(up / rec)).read_bytes():
                    bad.append("transform output differs from the committed %s/%s" % (rec, f.relative_to(up / rec)))
        revert(up / "p-reels-spotlight")
        t = up / "p-reels-spotlight" / "steps" / "05-render-scenes.md"
        t.write_text(t.read_text(encoding="utf-8").replace("compose the takeover cards with ffmpeg `overlay`",
                                                           "compose the cards with ffmpeg `overlay`"), encoding="utf-8")
        try:
            fn(up / "p-reels-spotlight", "fixture")
            bad.append("transform did not fail on a drifted step 05 anchor")
        except SystemExit:
            pass
except (Exception, SystemExit) as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad[:12]))
PY
)"
if [[ "$wi292_detail" == "ok" ]]; then
  pass "WI2.92 a failed spotlight takeover render fails step 05 with the hyperframes error, no still-card fallback (every copy)"
else
  fail "WI2.92 spotlight step 05 fails loudly instead of silent still-card takeovers" "$wi292_detail"
fi
rm -rf "$wi292_root"

echo "=== Case 66: WI2.94 — every spotlight takeover text line fits on one line inside the safe width ==="
# Observed 2026-10-21 (smoke 25, p-reels-spotlight on Render 69bc5ce): the tk-stat label
# "POSTS · SPECIALS · MOMENTS" showed on two lines (~4.6-9.6 s), and the tk-list title "CFW WRITES THE
# MONTH" and item 3 "FORMATTED FOR EVERY PLATFORM" wrapped (~30.4-36.3 s). WI2.83/WI2.85 fit only the big
# stat. Every p-reels-spotlight takeover template copy now keeps each single-line text on one line
# (white-space: nowrap) and shrinks its font from the design size until it fits its safe width (900 px;
# 786 px for list items; 880 px for the keyword word/support), so it stays >= 80 px from both frame edges;
# the text itself is never cut. Each template's own script runs in node with a fake DOM whose text width
# grows with font size (a fallback font until fonts load), so the old wrapping templates fail this case.
wi294_root="$(mktemp -d)"
wi294_detail="$(python3 - "$REPO_DIR" "$wi294_root" <<'PY'
import importlib.util, json, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
SIM = r"""
const vm = require('vm'), fs = require('fs');
const [tplPath, fillJson, emFallback, emLoaded] = process.argv.slice(2);
const fill = JSON.parse(fillJson);
let src = fs.readFileSync(tplPath, 'utf8');
for (const [k, v] of Object.entries(fill)) src = src.split('{{' + k + '}}').join(v);
const scripts = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (scripts.length !== 1) { console.log(JSON.stringify({ error: 'inline scripts: ' + scripts.length })); process.exit(0); }
const code = scripts[0].replace(/\{\{ID\}\}/g, 'tk0').replace(/\{\{DURATION\}\}/g, '4');
// Each line's design size and em/char (Oswald caps ~0.5, Inter 700 caps ~0.68, JetBrains Mono + tracking ~0.8).
const LINES = {
  '.js-eyebrow': [30, 0.8], '.js-label': [84, 0.5], '.js-title': [96, 0.5], '.item-text': [52, 0.68],
  '.js-word': [340, 0.5], '.js-support': [52, 0.68], '.js-attr': [34, 0.8], '.js-stat': [340, 0.5],
};
let scale = parseFloat(emFallback) / parseFloat(emLoaded);  // the fallback font until fonts load
function el(text, kind) {
  const [design, em] = LINES[kind] || [40, 0.5];
  return { kind, textContent: text, innerHTML: text, style: {}, childNodes: [], classList: { add() {} },
    appendChild() {},
    get scrollWidth() { const fs = parseFloat(this.style.fontSize) || design;
      return Math.round(fs * em * scale * this.textContent.length); } };
}
const text = k => (src.match(new RegExp('class="[^"]*' + k.replace(/^\./, '') + '[^"]*"[^>]*>([^<]*)')) || [, ''])[1];
const els = {};
for (const k of Object.keys(LINES)) els[k] = k === '.item-text'
  ? [...src.matchAll(/class="item-text">([^<]*)</g)].map(m => el(m[1], k)) : el(text(k), k);
const tl = new Proxy({}, { get: () => () => tl });
const readies = [];
const pick = s => Object.keys(els).find(k => s.endsWith(k));
const ctx = { window: {}, gsap: { timeline: () => tl }, parseFloat, Math, Array,
  document: {
    querySelector: s => { const k = pick(s); return k ? (Array.isArray(els[k]) ? els[k][0] : els[k]) : el('', ''); },
    querySelectorAll: s => { const k = pick(s); return k ? [].concat(els[k]) : []; },
    getElementById: id => (id.endsWith('-word') ? els['.js-word'] : el('', '')),
    createElement: () => el('', ''), createTextNode: t => ({ textContent: t }),
    fonts: { ready: { then: f => { readies.push(f); } } } } };
vm.runInNewContext(code, ctx);
scale = 1;                      // fonts finished loading
readies.forEach(f => f());
const out = {};
for (const k of ['.js-eyebrow', '.js-label', '.js-title', '.item-text', '.js-word', '.js-support', '.js-attr'])
  if (src.includes(k.slice(1) + '"') || src.includes(k.slice(1) + ' '))
    [].concat(els[k]).forEach((e, i) => { if (e.textContent) out[k + (Array.isArray(els[k]) ? i + 1 : '')] =
      { text: e.textContent, size: parseFloat(e.style.fontSize) || null, width: e.scrollWidth }; });
console.log(JSON.stringify(out));
"""
(root / "sim.js").write_text(SIM, encoding="utf-8")
BRAND = {"BG": "#111111", "ACCENT": "#3B82F6", "FG": "#F4F4F4"}
# The smoke-25 strings, plus longer lines and short lines that already fit.
CASES = {
    "tk-stat.html": [({"EYEBROW": "A FULL MONTH", "STAT": "45", "LABEL": "POSTS · SPECIALS · MOMENTS"},
                      {".js-label": 900, ".js-eyebrow": 900}),
                     ({"EYEBROW": "WHAT ONE BUSY OWNER GETS EVERY SINGLE MONTH", "STAT": "3X",
                       "LABEL": "MORE REPLIES FROM PEOPLE WHO ACTUALLY BUY"}, {".js-label": 900, ".js-eyebrow": 900})],
    "tk-list.html": [({"TITLE": "CFW WRITES THE MONTH", "ITEM1": "LEARNED HER VOICE", "ITEM2": "WRITES THE WHOLE MONTH",
                       "ITEM3": "FORMATTED FOR EVERY PLATFORM"},
                      {".js-title": 900, ".item-text1": 786, ".item-text2": 786, ".item-text3": 786})],
    "tk-keyword.html": [({"WORD": "TRANSFORMATIONAL", "SUPPORT": "ABOUT 30 MINUTES A WEEK, START TO FINISH"},
                         {".js-word": 880, ".js-support": 880})],
    "tk-quote.html": [({"QUOTE": "IT SOUNDS LIKE ME", "ATTR": "MARIA SANTOS, OWNER OF THE CORNER BAKERY CAFE"},
                       {".js-attr": 900})],
}
def sim(tpl, fill, ems):
    out = subprocess.run(["node", str(root / "sim.js"), str(tpl), json.dumps(dict(BRAND, **fill)), str(ems[0]), str(ems[1])],
                         capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        return {"error": out.stderr.strip()[-300:]}
    return json.loads(out.stdout)
def check(tpl, label):
    found = []
    for fill, limits in CASES[tpl.name]:
        for ems in ((0.5, 0.5), (0.6, 0.5), (0.4, 0.5)):  # same, wider and narrower fallback font
            r = sim(tpl, fill, ems)
            if "error" in r:
                found.append("%s: did not run: %s" % (label, r["error"])); break
            for key, lim in limits.items():
                line = r.get(key)
                if line is None:
                    found.append("%s: no %s line measured" % (label, key)); continue
                if line["width"] > lim:
                    found.append("%s: %r is %dpx wide, past its %dpx one-line safe width (fonts %s)"
                                 % (label, line["text"], line["width"], lim, ems))
            want = [v for k, v in fill.items() if k not in ("STAT", "QUOTE", "WORD")]
            got = [v["text"] for v in r.values() if isinstance(v, dict)]
            for v in want:
                if v not in got:
                    found.append("%s: line %r was cut or changed (%r)" % (label, v, got))
    # a line that already fits keeps its design size
    r = sim(tpl, {"EYEBROW": "A", "STAT": "1", "LABEL": "VIEWS", "TITLE": "THREE", "ITEM1": "ONE", "ITEM2": "TWO",
                  "ITEM3": "SIX", "WORD": "YES", "SUPPORT": "OK", "QUOTE": "HI", "ATTR": "ME"}, (0.5, 0.5))
    for key, size in ((".js-label", 84), (".js-eyebrow", 30), (".js-title", 96), (".item-text1", 52),
                      (".js-support", 52), (".js-attr", 34)):
        if key in r and r[key]["size"] not in (None, size):
            found.append("%s: a short %s line lost its %dpx design size (%r)" % (label, key, size, r[key]))
    body = tpl.read_text(encoding="utf-8")
    for cls in {"tk-stat.html": (".eyebrow", ".label"), "tk-list.html": (".title", ".item-text"),
                "tk-keyword.html": (".word", ".support"), "tk-quote.html": (".attr",)}[tpl.name]:
        if not re.search(r"\{\{ID\}\} " + re.escape(cls) + r" \{[^}]*white-space: nowrap", body):
            found.append("%s: %s is not kept on one line (white-space: nowrap)" % (label, cls))
    return found
try:
    skills = repo / "skills"
    tpls = sorted(p for p in skills.rglob("tk-*.html")
                  if p.parent.name == "templates" and p.parent.parent.name == "p-reels-spotlight" and p.name in CASES)
    tpls.sort(key=lambda p: list(CASES).index(p.name))  # report the smoke-25 templates (tk-stat, tk-list) first
    if len(tpls) != 8:
        bad.append("expected 8 p-reels-spotlight takeover template copies (4 x 2), found %d" % len(tpls))
    for name in CASES:
        if len({t.read_bytes() for t in tpls if t.name == name}) > 1:
            bad.append("the %s copies differ" % name)
    for tpl in tpls:
        bad += check(tpl, str(tpl.relative_to(repo)))
    spec = importlib.util.spec_from_file_location("ss294", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    fn, edits = getattr(ss, "apply_spotlight_takeover_line_fit", None), getattr(ss, "_SPOTLIGHT_LINE_EDITS", None)
    if fn is None or edits is None:
        bad.append("sync-skills.py has no apply_spotlight_takeover_line_fit transform (WI2.94)")
    else:
        # Restore the d9ec65d templates in a copy; the transform upgrades all four once, then is a no-op,
        # and its output is byte-identical to the committed bundle.
        up = root / "skills"
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            shutil.copytree(skills / rec, up / rec)
        def revert(t):
            text = t.read_text(encoding="utf-8")
            for old, new in reversed(edits[t.name]):
                text = text.replace(new, old)
            t.write_text(text, encoding="utf-8")
        for t in up.rglob("tk-*.html"):
            if t.name in edits:
                revert(t)
        if not check(up / "p-reels-spotlight" / "templates" / "tk-list.html", "restored"):
            bad.append("sanity: the restored d9ec65d tk-list.html was not caught")
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            n1 = fn(up / rec, rec); n2 = fn(up / rec, rec)
            if (n1, n2) != (4, 0):
                bad.append("transform on %s changed (%d, %d) file(s), expected (4, 0)" % (rec, n1, n2))
            for f in sorted(p for p in (up / rec).rglob("*") if p.is_file()):
                if f.read_bytes() != (skills / rec / f.relative_to(up / rec)).read_bytes():
                    bad.append("transform output differs from the committed %s/%s" % (rec, f.relative_to(up / rec)))
        t = up / "p-reels-spotlight" / "templates" / "tk-list.html"
        revert(t)
        t.write_text(t.read_text(encoding="utf-8").replace("#{{ID}} .item-text {", "#{{ID}} .item-label {"), encoding="utf-8")
        try:
            fn(up / "p-reels-spotlight", "fixture"); bad.append("transform did not fail on a drifted tk-list.html")
        except SystemExit:
            pass
        t.unlink()
        try:
            fn(up / "p-reels-spotlight", "p-reels-spotlight"); bad.append("transform did not fail on a missing tk-list.html")
        except SystemExit:
            pass
except (Exception, SystemExit) as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad[:12]))
PY
)"
if [[ "$wi294_detail" == "ok" ]]; then
  pass "WI2.94 spotlight takeover lines (tk-stat label, tk-list title/items, keyword, attribution) fit on one line (every copy)"
else
  fail "WI2.94 spotlight takeover text lines fit on one line inside the safe width" "$wi294_detail"
fi
rm -rf "$wi294_root"

echo "=== Case 67: WI2.90 — spotlight end card fails loudly when no room; SKILL.md honours cta_card off ==="
# Observed 2026-10-21 (independent review on WI2.89, Render 32549b7): (1) with under 1.0 s of bed left
# after the last word, step 06 only logged "end card skipped" and dropped the card, so the reel shipped
# with no CTA and no check failed (since WI2.89 the bed always has a tail, so this only happens through a
# bug); SKILL.md Step 8 already stops with exit 1 there. (2) SKILL.md never set CTA_CARD, so Step 2's
# "${CTA_CARD:-on}" was always on and an order with cta_card: off still got a ~3.5 s frozen silent tail
# (and Step 8 still rendered a card). Every step 06 copy now fails with the reason; both full SKILL.md
# copies read the order's cta_card into CTA_CARD (default on), Step 2 adds no tail and Step 8 renders no
# card when it is off. The bash blocks run under bash with stub ffmpeg/ffprobe/npx and the real cta-card.py.
wi290_root="$(mktemp -d)"
wi290_detail="$(python3 - "$REPO_DIR" "$wi290_root" <<'PY'
import importlib.util, json, os, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
FF = "#!/bin/sh\nprintf 'ffmpeg %s\\n' \"$*\" >> \"$WI290_LOG\"\nfor a; do last=$a; done\ncase \"$last\" in *.mp4) : > \"$last\";; esac\nexit 0\n"
FFPROBE = "#!/bin/sh\nprintf 'ffprobe %s\\n' \"$*\" >> \"$WI290_LOG\"\necho \"${WI290_BED:-45.0}\"\nexit 0\n"
NPX = ("#!/bin/sh\nprintf 'npx %s\\n' \"$*\" >> \"$WI290_LOG\"\n[ \"$2\" = render ] || exit 0\n"
       "if [ ! -f \"$3/index.html\" ]; then echo \"No composition found in $3\" >&2; exit 1; fi\n"
       "for a; do last=$a; done\n: > \"$last\"\nexit 0\n")
bin_dir = root / "bin"; bin_dir.mkdir()
for tool, body in (("ffmpeg", FF), ("ffprobe", FFPROBE), ("npx", NPX)):
    (bin_dir / tool).write_text(body); (bin_dir / tool).chmod(0o755)
SKILL_DIR = repo / "skills" / "p-reels-spotlight"
def first_bash(sec):
    m = re.search(r"```bash\n(.*?)```", sec, re.S)
    return m.group(1) if m else None
def fixture(work, words_end=41.6):
    shutil.rmtree(work, ignore_errors=True); (work / "work").mkdir(parents=True)
    (work / "work" / "words.json").write_text(json.dumps([{"text": "you.", "start": words_end - 0.3, "end": words_end}]))
    (work / "work" / "plan.json").write_text(json.dumps({"brand": {"bg": "#0F172A", "accent": "#F97316", "fg": "#F1F5F9"},
        "caption_groups": [{"start": words_end - 0.3, "end": words_end, "words": [{"w": "you.", "s": words_end - 0.3, "e": words_end}]}]}))
    (work / "work" / "polished.mp4").write_bytes(b"polished-bed")
    (work / "brief.json").write_text(json.dumps({"brand": {"name": "Test Brand", "handle": "@test", "cta": "Follow Test Brand"}}))
def sh(work, script, bed, extra_env=None):
    (work / "run.sh").write_text(script)
    log = work / "calls.log"
    env = dict(os.environ, PATH="%s:%s" % (bin_dir, os.environ["PATH"]), WI290_LOG=str(log), WI290_BED=str(bed),
               CFW_RENDER_SKILLS_DIR=str(SKILL_DIR.parent))
    for k in ("CTA_CARD", "MUSIC"):
        env.pop(k, None)
    env.update(extra_env or {})
    p = subprocess.run(["bash", "run.sh"], cwd=work, env=env, capture_output=True, text=True, timeout=60)
    calls = log.read_text().splitlines() if log.exists() else []
    return {"rc": p.returncode, "out": (p.stdout + p.stderr)[-400:],
            "renders": [c for c in calls if c.startswith("npx ") and " render " in c],
            "overlay": [c for c in calls if "overlay=enable" in c]}
def run_step(step, case, bed, card="on"):
    work = root / case; fixture(work)
    sec = step.read_text(encoding="utf-8").split("### 4. CTA end card", 1)[1].split("### 5.", 1)[0]
    code = first_bash(sec)
    if code is None:
        return {"error": "no bash block in section 4"}
    r = sh(work, "set -u\nCTA_CARD=%s; CTA_DURATION=3.0; BED_DUR=%s\nSKILL_DIR=%s\n%s" % (card, bed, SKILL_DIR, code), bed)
    r["assembled"] = (work / "work" / "assembled.mp4").exists()
    return r
def skill_blocks(doc):
    t = doc.read_text(encoding="utf-8")
    setup = first_bash(t.split("Set up variables:", 1)[1]) if "Set up variables:" in t else None
    tail = first_bash(t.split("**End-card tail (WI2.89, mandatory):**", 1)[1]) if "**End-card tail (WI2.89" in t else None
    s8 = first_bash(t.split("### Step 8", 1)[1].split("\n### ", 1)[0]) if "### Step 8" in t else None
    return setup, tail, s8
try:
    skills = repo / "skills"
    steps = sorted(p for p in skills.rglob("06-assemble.md")
                   if p.parent.name == "steps" and p.parent.parent.name.startswith("p-reels-spotlight"))
    if len(steps) != 3:
        bad.append("expected 3 p-reels-spotlight steps/06-assemble.md copies, found %d" % len(steps))
    if len({s.read_bytes() for s in steps}) > 1:
        bad.append("the 06-assemble.md copies differ")
    for step in steps:
        rel = step.relative_to(repo)
        t = step.read_text(encoding="utf-8")
        if "end card skipped" in t or "the card is skipped with one log line" in t:
            bad.append("%s: step 06 still skips the end card silently when there is no room" % rel)
        # Speech to 41.60 s on a 41.67 s bed: the step 01 tail is missing -> fail loudly, no reel.
        r = run_step(step, "noroom", 41.67)
        if "error" in r:
            bad.append("%s: %s" % (rel, r["error"])); continue
        if r["rc"] == 0 or r["assembled"] or r["overlay"] or r["renders"] or "end card: only" not in r["out"] \
                or "tail (WI2.89) is missing" not in r["out"]:
            bad.append("%s: under 1.0 s after the last word, step 06 did not stop with the reason (rc %s, assembled %s): %s"
                       % (rel, r["rc"], r["assembled"], r["out"]))
        r = run_step(step, "room", 45.0)
        if r.get("rc") != 0 or not r.get("assembled") or not r.get("overlay"):
            bad.append("%s: a card with room no longer renders (rc %s): %s" % (rel, r.get("rc"), r.get("out")))
        r = run_step(step, "off", 41.67, card="off")
        if r.get("rc") != 0 or not r.get("assembled") or r.get("overlay") or r.get("renders"):
            bad.append("%s: cta_card off no longer passes with no card (rc %s): %s" % (rel, r.get("rc"), r.get("out")))
    docs = (skills / "p-reels-spotlight" / "SKILL.md", skills / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight" / "SKILL.md")
    for doc in docs:
        rel = doc.relative_to(repo)
        setup, tail, s8 = skill_blocks(doc)
        if not setup or not tail or not s8:
            bad.append("%s: setup / Step 2 tail / Step 8 bash block not found" % rel); continue
        if 'CTA_CARD="${CTA_CARD:-on}"' not in setup or "`cta_card` comes from the order" not in doc.read_text(encoding="utf-8"):
            bad.append("%s: SKILL.md does not read the order's cta_card into CTA_CARD next to CTA_TEXT/CTA_HANDLE" % rel)
        work = root / ("setup-" + doc.parent.parent.name); fixture(work)
        r = sh(work, "set -u\n" + setup + '\necho "CTA_CARD=$CTA_CARD"\n', 45.0)
        if r["rc"] != 0 or "CTA_CARD=on" not in r["out"]:
            bad.append("%s: the setup block does not default CTA_CARD to on (rc %s): %s" % (rel, r["rc"], r["out"]))
        r = sh(work, "set -u\n" + setup + '\necho "CTA_CARD=$CTA_CARD"\n', 45.0, {"CTA_CARD": "off"})
        if r["rc"] != 0 or "CTA_CARD=off" not in r["out"]:
            bad.append("%s: the setup block drops the order's cta_card off (rc %s): %s" % (rel, r["rc"], r["out"]))
        # The order says off: Step 2 adds no tail and Step 8 renders no card, with or without bed room.
        r = sh(work, "set -u\n" + setup + "\n" + tail, 41.67, {"CTA_CARD": "off"})
        if r["rc"] != 0 or "cta_card off, no tail" not in r["out"]:
            bad.append("%s: Step 2 still adds the end-card tail for cta_card off (rc %s): %s" % (rel, r["rc"], r["out"]))
        for bed in (41.67, 45.0):
            work = root / ("s8off-%s-%s" % (doc.parent.parent.name, bed)); fixture(work)
            pre = 'set -u\nW="%s/work"; OUT_RAW="%s/out.mp4"; SKILL_DIR=%s\nCTA_TEXT="Try it"; CTA_HANDLE=""; BRAND_NAME=""\n' % (work, work, SKILL_DIR)
            r = sh(work, pre + 'CTA_CARD="${CTA_CARD:-on}"\n' + s8, bed, {"CTA_CARD": "off"})
            out = work / "out.mp4"
            if r["rc"] != 0 or r["renders"] or r["overlay"] or not out.is_file() or out.read_bytes() != b"polished-bed":
                bad.append("%s: Step 8 with cta_card off (bed %s) still renders or overlays an end card (rc %s, renders %d): %s"
                           % (rel, bed, r["rc"], len(r["renders"]), r["out"]))
        work = root / ("s8on-" + doc.parent.parent.name); fixture(work)
        pre = 'set -u\nW="%s/work"; OUT_RAW="%s/out.mp4"; SKILL_DIR=%s\nCTA_TEXT="Try it"; CTA_HANDLE=""; BRAND_NAME=""\n' % (work, work, SKILL_DIR)
        r = sh(work, pre + 'CTA_CARD="${CTA_CARD:-on}"\n' + s8, 45.0)
        if r["rc"] != 0 or not r["renders"] or not r["overlay"]:
            bad.append("%s: Step 8 with cta_card on (default) no longer renders the card (rc %s): %s" % (rel, r["rc"], r["out"]))
    spec = importlib.util.spec_from_file_location("ss290", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    fn, files = getattr(ss, "apply_spotlight_end_card_room", None), getattr(ss, "_SPOTLIGHT_CTA_ROOM_FILES", None)
    if fn is None or files is None:
        bad.append("sync-skills.py has no apply_spotlight_end_card_room (WI2.90)")
    else:
        up = root / "skills"
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            shutil.copytree(skills / rec, up / rec)
        def revert(base):
            for rel, full_only, edits in files:
                if full_only and base.name != "p-reels-spotlight":
                    continue
                t = (base / rel).read_text(encoding="utf-8")
                for old, new in reversed(edits):
                    t = t.replace(new, old)
                (base / rel).write_text(t, encoding="utf-8")
        for base in (up / "p-reels-spotlight", up / "p-reels-spotlight-heygen",
                     up / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight"):
            revert(base)
        r = run_step(up / "p-reels-spotlight" / "steps" / "06-assemble.md", "restored", 41.67)
        if r.get("rc") != 0 or "end card skipped" not in r.get("out", ""):
            bad.append("sanity: the restored 48ef94d step 06 did not skip silently (%r)" % {k: r.get(k) for k in ("rc", "out")})
        for rec, want in (("p-reels-spotlight", (2, 0)), ("p-reels-spotlight-heygen", (3, 0))):
            got = (fn(up / rec, rec), fn(up / rec, rec))
            if got != want:
                bad.append("transform on %s changed %r file(s), expected %r" % (rec, got, want))
            for f in sorted(p for p in (up / rec).rglob("*") if p.is_file()):
                if f.read_bytes() != (skills / rec / f.relative_to(up / rec)).read_bytes():
                    bad.append("transform output differs from the committed %s/%s" % (rec, f.relative_to(up / rec)))
        revert(up / "p-reels-spotlight")
        t = up / "p-reels-spotlight" / "steps" / "06-assemble.md"
        t.write_text(t.read_text(encoding="utf-8").replace("    CTA_CARD=off\n", "    CTA_CARD=no\n"), encoding="utf-8")
        try:
            fn(up / "p-reels-spotlight", "fixture")
            bad.append("transform did not fail on a drifted step 06 anchor")
        except SystemExit:
            pass
        (up / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight" / "SKILL.md").unlink()
        try:
            fn(up / "p-reels-spotlight-heygen", "p-reels-spotlight-heygen")
            bad.append("transform did not fail on a missing .hub SKILL.md")
        except SystemExit:
            pass
except (Exception, SystemExit) as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad[:12]))
PY
)"
if [[ "$wi290_detail" == "ok" ]]; then
  pass "WI2.90 spotlight step 06 fails loudly with under 1.0 s of end-card room; SKILL.md honours cta_card off (no tail, no card)"
else
  fail "WI2.90 spotlight end card fails loudly when no room; SKILL.md honours cta_card off" "$wi290_detail"
fi
rm -rf "$wi290_root"

echo "=== Case 68: WI2.91 — the spotlight typing takeover types a prompt with \\, CR/LF, <, & and quotes exactly ==="
# Observed 2026-10-21 (independent review 01a15e05-5322 of Render 69bc5ce): step 05 (and SKILL.md Step 5)
# put html.escape(PROMPT) into the scene's `var PROMPT_TEXT = "{{PROMPT}}"` JS literal. html.escape does not
# escape a backslash (it changed the typed text) or a carriage return (CRLF text broke the script, so the
# HyperFrames render failed: "invalid_inline_script_syntax"). Also c-typing-ui's card label "The prompt ·
# paste this" was hard-coded on every spotlight reel. This case runs the real step 05 Part B assembler of
# every copy on hostile prompts, checks the slotted file has no raw CR / U+2028 / </script> / unfilled key,
# runs its script (fake DOM + GSAP, as in Case 63) and checks the typed text is the prompt exactly (CR/CRLF
# as one line break), and that the label is CARD_LABEL (default "The prompt"). The SKILL.md copies and the
# sync transform (idempotent, fail-fast) are checked too.
wi291_root="$(mktemp -d)"
wi291_detail="$(python3 - "$REPO_DIR" "$wi291_root" <<'PY'
import importlib.util, json, re, shutil, subprocess, sys
from pathlib import Path
repo, root = Path(sys.argv[1]), Path(sys.argv[2])
bad = []
SIM = r"""
const vm = require('vm'), fs = require('fs');
const els = {};
function el(id) { return els[id] || (els[id] = { id, textContent: '', style: {}, classList: { add() {} } }); }
const decode = s => s.replace(/&#10;/g, '\n').replace(/&quot;/g, '"').replace(/&#x27;/g, "'")
                     .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
const tweens = [];
function timeline() { const tl = { to(t, v) { tweens.push({ tl, t, v }); return tl; }, fromTo() { return tl; } }; return tl; }
const document = { getElementById: el, querySelector: () => null,
  createElement: () => { const o = { value: '' }; Object.defineProperty(o, 'innerHTML', { set(s) { o.value = decode(s); } }); return o; } };
const ctx = vm.createContext({ window: {}, document, gsap: { timeline }, parseFloat, Math });
const out = {};
for (const f of process.argv.slice(2)) {
  const src = fs.readFileSync(f, 'utf8');
  const inline = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  if (inline.length !== 1) { out[f] = { error: 'inline scripts ' + inline.length }; continue; }
  try { new vm.Script(inline[0]); } catch (e) { out[f] = { error: 'syntax: ' + e.message }; continue; }
  vm.runInContext(inline[0], ctx);
}
for (const tw of tweens) if (tw.v && typeof tw.v.onUpdate === 'function') { tw.t.n = tw.v.n; tw.v.onUpdate(); }
for (const id of Object.keys(els)) if (/-ts-typed$/.test(id)) out[id] = els[id].textContent;
console.log(JSON.stringify(out));
"""
(root / "sim.js").write_text(SIM, encoding="utf-8")
def part_b(step):
    m = re.search(r'^python3 - work "\$SKILL_DIR" "\$TYPING_DIR" <<\'PY\'\n(.*?)^PY$', step.read_text(encoding="utf-8"), re.S | re.M)
    return m.group(1) if m else None
PROMPTS = ['Rewrite "C:\\new\\table" & <b>bold</b>\r\nkeep it\'s {{ACCENT}} </script> \\o/',
           "line one\rline two\u2028three\\\\ end\\",
           "Plan my posts\nfor Friday"]
WANT = [p.replace("\r\n", "\n").replace("\r", "\n") for p in PROMPTS]
plan = {"duration": 14.0, "brand": {"bg": "#111111", "accent": "#3B82F6", "fg": "#F4F4F4"}, "takeovers": [
    {"start": 1.0, "end": 4.5, "template": "tk-typing-ui", "fill": {"LABEL": "CFW", "PROMPT": PROMPTS[0],
     "BOTTOM_TAG": "a\\b\r\nc"}},
    {"start": 5.0, "end": 9.0, "template": "tk-typing-ui", "fill": {"LABEL": "CFW", "PROMPT": PROMPTS[1],
     "CARD_LABEL": "Try <this> & that"}},
    {"start": 10.0, "end": 13.0, "template": "tk-typing-ui", "fill": {"LABEL": "CFW", "PROMPT": PROMPTS[2]}}]}
LABELS = ["The prompt", "Try &lt;this&gt; &amp; that", "The prompt"]
try:
    skills = repo / "skills"
    roots = [skills / "p-reels-spotlight", skills / "p-reels-spotlight-heygen",
             skills / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight"]
    for r in roots:
        step = r / "steps" / "05-render-scenes.md"
        rel = step.relative_to(repo)
        code = part_b(step)
        if code is None:
            bad.append("%s: no step 05 Part B assembler block" % rel); continue
        skill = skills / "p-reels-spotlight"
        w = root / ("w-" + r.name + ("-hub" if r.parent.name == ".hub" else ""))
        w.mkdir()
        (w / "plan.json").write_text(json.dumps(plan), encoding="utf-8")
        (w / "base.mp4").write_bytes(b"")
        (root / "partb.py").write_text(code, encoding="utf-8")
        out = subprocess.run([sys.executable, str(root / "partb.py"), str(w), str(skill), str(skill / ".hub" / "c-typing-ui")],
                             capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            bad.append("%s: assembler failed: %s" % (rel, out.stderr.strip()[-200:])); continue
        files = []
        for i in range(len(PROMPTS)):
            f = w / "comp" / "compositions" / ("tk%d.html" % i)
            text = f.read_text(encoding="utf-8")
            files.append(str(f))
            script = text.split("<script>", 1)[-1]
            if "\r" in text or "\u2028" in text or "\u2029" in text:
                bad.append("%s: tk%d carries a raw CR / U+2028 / U+2029" % (rel, i))
            if script.count("</script>") != 1:
                bad.append("%s: tk%d's prompt closes the inline script early" % (rel, i))
            if re.search(r"\{\{[A-Z_]+\}\}", text):
                bad.append("%s: tk%d has an unfilled {{KEY}} or a prompt key was filled" % (rel, i))
            if "paste this" in text.lower():
                bad.append("%s: tk%d still shows c-typing-ui's 'The prompt · paste this' label" % (rel, i))
            if ('id="tk%d-ts-label">%s</div>' % (i, LABELS[i])) not in text:
                bad.append("%s: tk%d card label is not %r" % (rel, i, LABELS[i]))
        sim = subprocess.run(["node", str(root / "sim.js")] + files, capture_output=True, text=True, timeout=60)
        got = json.loads(sim.stdout) if sim.returncode == 0 and sim.stdout.strip() else {"error": sim.stderr[-300:]}
        errs = {k: v for k, v in got.items() if isinstance(v, dict) or k == "error"}
        if errs:
            bad.append("%s: typing scripts did not run: %s" % (rel, json.dumps(errs)[:300])); continue
        for i, want in enumerate(WANT):
            if got.get("tk%d-ts-typed" % i) != want:
                bad.append("%s: tk%d typed %r, expected exactly %r" % (rel, i, got.get("tk%d-ts-typed" % i), want))
    docs = (skills / "p-reels-spotlight" / "SKILL.md", skills / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight" / "SKILL.md")
    spec = importlib.util.spec_from_file_location("ss291", repo / "scripts" / "sync-skills.py")
    ss = importlib.util.module_from_spec(spec); spec.loader.exec_module(ss)
    fn, pfiles = getattr(ss, "apply_spotlight_typing_prompt", None), getattr(ss, "_SPOTLIGHT_PROMPT_FILES", None)
    if fn is None or pfiles is None:
        bad.append("sync-skills.py has no apply_spotlight_typing_prompt (WI2.91)")
    else:
        for doc in docs:
            text = doc.read_text(encoding="utf-8")
            if ss.SPOTLIGHT_PROMPT_SKILL not in text or ss.SPOTLIGHT_LABEL_SKILL not in text \
                    or 'm["PROMPT"] = html.escape(' in text:
                bad.append("%s: Step 5 does not JSON-encode the prompt / fill CARD_LABEL" % doc.relative_to(repo))
        up = root / "skills"
        for rec in ("p-reels-spotlight", "p-reels-spotlight-heygen"):
            shutil.copytree(skills / rec, up / rec)
        def revert(base):
            for rel, full_only, edits in pfiles:
                if full_only and base.name != "p-reels-spotlight":
                    continue
                t = (base / rel).read_text(encoding="utf-8")
                for old, new in reversed(edits):
                    t = t.replace(new, old)
                (base / rel).write_text(t, encoding="utf-8")
        for base in (up / "p-reels-spotlight", up / "p-reels-spotlight-heygen",
                     up / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight"):
            revert(base)
        # Sanity: the restored (a0714c9) step 05 really breaks on the CR prompt.
        w = root / "restored"; w.mkdir()
        (w / "plan.json").write_text(json.dumps(plan), encoding="utf-8"); (w / "base.mp4").write_bytes(b"")
        (root / "partb.py").write_text(part_b(up / "p-reels-spotlight" / "steps" / "05-render-scenes.md"), encoding="utf-8")
        subprocess.run([sys.executable, str(root / "partb.py"), str(w), str(up / "p-reels-spotlight"),
                        str(up / "p-reels-spotlight" / ".hub" / "c-typing-ui")], capture_output=True, text=True, timeout=60)
        sim = subprocess.run(["node", str(root / "sim.js"), str(w / "comp" / "compositions" / "tk0.html")],
                             capture_output=True, text=True, timeout=60)
        if "syntax" not in sim.stdout:
            bad.append("sanity: the restored a0714c9 step 05 did not break the script on a CRLF prompt (%s)" % sim.stdout[:200])
        for rec, want in (("p-reels-spotlight", (3, 0)), ("p-reels-spotlight-heygen", (5, 0))):
            got = (fn(up / rec, rec), fn(up / rec, rec))
            if got != want:
                bad.append("transform on %s changed %r file(s), expected %r" % (rec, got, want))
            for f in sorted(p for p in (up / rec).rglob("*") if p.is_file()):
                if f.read_bytes() != (skills / rec / f.relative_to(up / rec)).read_bytes():
                    bad.append("transform output differs from the committed %s/%s" % (rec, f.relative_to(up / rec)))
        revert(up / "p-reels-spotlight")
        t = up / "p-reels-spotlight" / "steps" / "05-render-scenes.md"
        t.write_text(t.read_text(encoding="utf-8").replace("  # decoded in-page\n", "\n"), encoding="utf-8")
        try:
            fn(up / "p-reels-spotlight", "fixture")
            bad.append("transform did not fail on a drifted step 05 anchor")
        except SystemExit:
            pass
        (up / "p-reels-spotlight-heygen" / ".hub" / "p-reels-spotlight" / "SKILL.md").unlink()
        try:
            fn(up / "p-reels-spotlight-heygen", "p-reels-spotlight-heygen")
            bad.append("transform did not fail on a missing .hub SKILL.md")
        except SystemExit:
            pass
except (Exception, SystemExit) as exc:
    bad.append("error: %r" % exc)
print("ok" if not bad else "; ".join(bad[:12]))
PY
)"
if [[ "$wi291_detail" == "ok" ]]; then
  pass "WI2.91 spotlight typing takeover types a prompt with \\, CR/LF, <, & and quotes exactly; card label is CARD_LABEL (every copy)"
else
  fail "WI2.91 spotlight typing takeover prompt escaping and card label" "$wi291_detail"
fi
rm -rf "$wi291_root"

echo "-------------------------------------"
echo "PASS: $PASS_COUNT   FAIL: $FAILURES"
if (( FAILURES > 0 )); then
  exit 1
fi
exit 0
