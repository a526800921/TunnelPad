#!/usr/bin/env python3
"""Isolated fake-cloud/process failure matrix; never reads real cloud credentials."""
import json, os, pathlib, signal, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
ENTRY = ROOT / 'scripts/update-ecs-ssh-ip'
FIXTURE = ROOT / 'Tests/fixtures/update-ecs-ssh-ip'
RULE = dict(Description='tunnelpad-dynamic-ssh-managed', Direction='ingress', IpProtocol='TCP', PortRange='22/22', Policy='Accept', Priority='1', NicType='intranet', SourceCidrIp='45.67.89.100/32', SecurityGroupRuleId='sgr-old')
with tempfile.TemporaryDirectory(prefix='tunnelpad-supervision-') as temporary:
    base = pathlib.Path(temporary)
    def setup(name):
        p = base/name; p.mkdir(); (p/'credentials').touch()
        (p/'config').write_text(f'TUNNELPAD_ALIYUN_CONFIG="{p}/credentials"\nALIBABA_REGION_ID=cn-fixture\nECS_SECURITY_GROUP_ID=sg-fixture\n')
        (p/'state.json').write_text(json.dumps({'Permissions': {'Permission': [RULE]}}))
        (p/'calls').touch()
        e = dict(os.environ, TUNNELPAD_CONFIG_FILE=str(p/'config'), TUNNELPAD_PREFLIGHT_STATE_DIR=str(p/'private'), TUNNELPAD_LOCK_DIR=str(p/'legacy'), FAKE_STATE_FILE=str(p/'state.json'), FAKE_CALL_LOG=str(p/'calls'), CURL_BIN=str(FIXTURE/'fake-curl'), ALIYUN_BIN=str(FIXTURE/'fake-aliyun'), FAKE_IP_1='45.67.89.101', FAKE_IP_2='45.67.89.101', TUNNELPAD_IP_ENDPOINT_1='https://endpoint-one.test', TUNNELPAD_IP_ENDPOINT_2='https://endpoint-two.test')
        return p,e
    def run(e,*args):
        return subprocess.run([str(ENTRY),*args,'--result-json'], env=e, capture_output=True, text=True, timeout=8)
    p,e=setup('invalid-config')
    with (p/'config').open('a') as f: f.write('echo SECRET-CONFIG\nif then\n')
    helper=p/'helper';helper.write_text('#!/bin/bash\ntouch "'+str(p/'helper-called')+'"\n');helper.chmod(0o700)
    r=run(dict(e,TUNNELPAD_PREFLIGHT_HELPER=str(helper)))
    assert r.returncode==2 and json.loads(r.stdout)['sanitizedCode']=='configuration_invalid'
    assert not r.stderr and 'SECRET' not in r.stdout and not (p/'helper-called').exists() and not (p/'calls').read_text()
    print('PASS invalid-config-no-helper-no-leak')
    p,e=setup('new-priority')
    r=run(dict(e,FAKE_NEW_PRIORITY='2'))
    assert r.returncode==4 and 'RevokeSecurityGroup' not in (p/'calls').read_text()
    assert len(json.loads((p/'state.json').read_text())['Permissions']['Permission'])==2
    assert run(e).returncode==4 and 'RevokeSecurityGroup' not in (p/'calls').read_text()
    print('PASS unexpected-new-priority-no-revoke-or-adoption')
    p,e=setup('third-rule')
    assert run(dict(e,FAKE_REVOKE_FAIL='1')).returncode==6
    state=json.loads((p/'state.json').read_text()); state['Permissions']['Permission'].append(dict(RULE,SecurityGroupRuleId='sgr-foreign',SourceCidrIp='45.67.89.99/32'));(p/'state.json').write_text(json.dumps(state))
    calls=(p/'calls').read_text(); assert run(e).returncode==4
    assert (p/'calls').read_text().count('RevokeSecurityGroup')==calls.count('RevokeSecurityGroup')
    print('PASS pending-third-rule-no-write')
    p,e=setup('mutated-old');assert run(dict(e,FAKE_REVOKE_FAIL='1')).returncode==6
    state=json.loads((p/'state.json').read_text());state['Permissions']['Permission'][0]['Priority']='2';(p/'state.json').write_text(json.dumps(state))
    calls=(p/'calls').read_text();assert run(e).returncode==4;assert (p/'calls').read_text().count('RevokeSecurityGroup')==calls.count('RevokeSecurityGroup')
    print('PASS pending-attribute-change-no-write')
    p,e=setup('readonly-pending');assert run(dict(e,FAKE_REVOKE_FAIL='1')).returncode==6
    journal=next((p/'private').glob('*.journal'));before=journal.read_bytes();calls=(p/'calls').read_text();assert run(e,'--check').returncode==0
    assert journal.read_bytes()==before;assert (p/'calls').read_text().count('RevokeSecurityGroup')==calls.count('RevokeSecurityGroup')
    journal.unlink();journal.symlink_to(p/'credentials');assert run(e).returncode==2
    print('PASS readonly-journal-and-symlink-refusal')
    p,e=setup('ip-changes');assert run(dict(e,FAKE_REVOKE_FAIL='1')).returncode==6
    assert run(dict(e,FAKE_IP_1='45.67.89.102',FAKE_IP_2='45.67.89.102')).returncode==0
    rules=json.loads((p/'state.json').read_text())['Permissions']['Permission'];assert len(rules)==1 and rules[0]['SourceCidrIp']=='45.67.89.102/32'
    actions=[line.split()[0] for line in (p/'calls').read_text().splitlines()];start=actions.index('RevokeSecurityGroup')+1
    assert actions[start:].index('RevokeSecurityGroup')<actions[start:].index('AuthorizeSecurityGroup')
    print('PASS pending-ip-change-finishes-before-next-rotation')
    p,e=setup('auth');denied=p/'denied';denied.write_text('#!/bin/bash\nprintf \'%s\\n\' \'{"Code":"Forbidden.RAM","Message":"SECRET"}\'\n');denied.chmod(0o700)
    r=run(dict(e,ALIYUN_BIN=str(denied)));assert r.returncode==4 and json.loads(r.stdout)['category']=='auth' and 'SECRET' not in r.stdout
    assert json.loads(run(e).stdout)['sanitizedCode']=='auth_cooldown';assert not (p/'calls').read_text()
    auth=next((p/'private').glob('*.auth'));auth.write_text('0');assert run(e).returncode==0
    print('PASS auth-cooldown-and-readonly-revalidation')
    # TERM-resistant descendant holds inherited pipes and lock; supervisor must kill its group.
    p,e=setup('deadline');hung=p/'hung';hung.write_text('#!/bin/bash\ntrap "" TERM INT\necho $$ > "$PID_FILE"\n/bin/sleep 120 &\nwait\n');hung.chmod(0o700)
    e.update(CURL_BIN=str(hung),PID_FILE=str(p/'pid'),TUNNELPAD_PREFLIGHT_TIMEOUT_MS='1000')
    start=time.monotonic();r=run(e);assert r.returncode!=0 and time.monotonic()-start<6,r
    pid=int((p/'pid').read_text());
    try:os.kill(pid,0);raise AssertionError('orphan alive')
    except ProcessLookupError:pass
    assert not (p/'legacy').exists(),r.stdout
    print('PASS bounded-term-resistant-descendants')
    p,e=setup('guardian-crash');hung=p/'hung';hung.write_text('#!/bin/bash\ntrap "" TERM INT\necho $$ > "$PID_FILE"\n/bin/sleep 120 &\nwait\n');hung.chmod(0o700);e.update(CURL_BIN=str(hung),PID_FILE=str(p/'pid'))
    child=subprocess.Popen([str(ENTRY),'--result-json'],env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    end=time.monotonic()+3
    while not (p/'pid').exists() and time.monotonic()<end:time.sleep(.01)
    assert (p/'pid').exists()
    # Same ECS resource with another CLI profile is still locked.
    other=dict(e,ALIBABA_PROFILE='other-profile');assert run(other).returncode==7
    child.kill();child.communicate(timeout=3)
    pid=int((p/'pid').read_text());end=time.monotonic()+3
    while time.monotonic()<end:
        try:os.kill(pid,0)
        except ProcessLookupError:break
        time.sleep(.01)
    else:raise AssertionError('guardian death left live worker subtree')
    e['CURL_BIN']=str(FIXTURE/'fake-curl');assert run(e).returncode==0
    print('PASS guardian-crash-reclaims-trusted-lock-and-profile-mutex')
