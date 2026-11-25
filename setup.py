#!/usr/bin/env python3
import argparse, os, time, base64, plistlib, subprocess, pathlib, re
p=argparse.ArgumentParser(description='AirSIM developer capability setup (official API)')
p.add_argument('--apply',action='store_true')
p.add_argument('--bundle',help='Bundle ID (prompted when omitted)')
p.add_argument('--verify')
p.add_argument('--certificate')
p.add_argument('--device',action='append')
p.add_argument('--profile-name',default='AirSIM Development')
a=p.parse_args()
CAPS=['PUSH_NOTIFICATIONS','ASSOCIATED_DOMAINS','AUTOFILL_CREDENTIAL_PROVIDER','APP_GROUPS','ICLOUD','APPLE_ID_AUTH']
EXPECTED={
'com.apple.developer.dialing-app':True,
'com.apple.security.application-groups':['group.songzixy.example'+str(i) for i in range(1,6)],
'com.apple.developer.calling-app':True,
'com.apple.developer.associated-domains':'*',
'com.apple.developer.authentication-services.autofill-credential-provider':True,
'com.apple.developer.messaging-app':True,
'application-identifier':'TEAM_PLACEHOLDER.BUNDLE_PLACEHOLDER',
'keychain-access-groups':['TEAM_PLACEHOLDER.*','com.apple.token'],
'get-task-allow':True,
'com.apple.developer.team-identifier':'TEAM_PLACEHOLDER',
'com.apple.developer.ubiquity-kvstore-identifier':'TEAM_PLACEHOLDER.*',
'com.apple.developer.icloud-services':'*',
'com.apple.developer.icloud-container-identifiers':[],
'com.apple.developer.icloud-container-development-container-identifiers':[],
'com.apple.developer.usernotifications.communication':True,
'com.apple.developer.kernel.increased-debugging-memory-limit':True,
'com.apple.developer.ubiquity-container-identifiers':[],
'com.apple.developer.usernotifications.time-sensitive':True,
'com.apple.developer.kernel.increased-memory-limit':True,
'aps-environment':'development',
'com.apple.developer.icloud-extended-share-access':['InProcessShareAccessRequests','InProcessShareOwnerParticipantInfo','InProcessOneTimeLinks'],
'com.apple.developer.carrier-messaging-app':True,
'com.apple.developer.kernel.extended-virtual-addressing':True,
'com.apple.developer.applesignin':['Default']}
def valid(s): return re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',s)
def read_profile(path):
    raw=subprocess.check_output(['openssl','cms','-verify','-inform','DER','-in',path,'-noverify'],stderr=subprocess.DEVNULL)
    return plistlib.loads(raw)['Entitlements']
if a.verify:
    e=read_profile(a.verify)
    if not a.bundle: a.bundle=e['application-identifier'].split('.',1)[1]
if not a.bundle:
    while True:
        try: candidate=input('Enter target Bundle ID: ').strip()
        except (EOFError,KeyboardInterrupt): raise SystemExit('Cancelled')
        if valid(candidate): a.bundle=candidate; break
        print('Invalid explicit Bundle ID.')
if not valid(a.bundle): raise SystemExit('Invalid explicit Bundle ID.')
if a.verify:
    team=e.get('com.apple.developer.team-identifier','')
    def substitute(v):
        if isinstance(v,str): return v.replace('TEAM_PLACEHOLDER',team).replace('BUNDLE_PLACEHOLDER',a.bundle)
        if isinstance(v,list): return [substitute(x) for x in v]
        return v
    failures=0
    for k,v in EXPECTED.items():
        v=substitute(v); actual=e.get(k)
        ok=k in e and (set(v)==set(actual) if isinstance(v,list) and isinstance(actual,list) else v==actual)
        print('OK' if ok else 'DIFF',k,repr(actual)); failures+=not ok
    print('Differences:',failures,'(CMS integrity only; trust chain not checked)')
    raise SystemExit(bool(failures))
print('Bundle:',a.bundle,'API capabilities:',', '.join(CAPS))
print('Portal checklist: Default Calling App; Default Dialing App; Default Messaging App; Carrier Messaging App; Communication Notifications; Time Sensitive Notifications; Increased Memory Limit; Increased Debugging Memory Limit; Extended Virtual Addressing; iCloud Extended Share Access.')
print('Portal: configure iCloud compatibility and Sign in with Apple primary/group; create/assign App Groups:',EXPECTED['com.apple.security.application-groups'])
if not a.apply: raise SystemExit('Preview only. Use --apply to change account.')
if input(f'Apply capabilities to {a.bundle}? Type YES: ').strip()!='YES': raise SystemExit('Cancelled')
import jwt, requests
key=pathlib.Path(os.environ['ASC_KEY_PATH']).read_text()
kid=os.environ['ASC_KEY_ID']; issuer=os.environ['ASC_ISSUER_ID']
def api(method,path,body=None,params=None):
    now=int(time.time())
    token=jwt.encode({'iss':issuer,'iat':now,'exp':now+600,'aud':'appstoreconnect-v1'},key,algorithm='ES256',headers={'kid':kid,'typ':'JWT'})
    r=requests.request(method,'https://api.appstoreconnect.apple.com/v1/'+path,json=body,params=params,headers={'Authorization':'Bearer '+token},timeout=40)
    if not r.ok: raise RuntimeError(f'{r.status_code}: {r.text}')
    return r.json()['data']
def rel(t,i): return {'type':t,'id':i}
rows=api('GET','bundleIds',params={'filter[identifier]':a.bundle})
if len(rows)>1: raise SystemExit('Ambiguous bundle ID')
bid=rows[0]['id'] if rows else api('POST','bundleIds',{'data':{'type':'bundleIds','attributes':{'identifier':a.bundle,'name':a.bundle,'platform':'IOS'}}})['id']
existing={x['attributes']['capabilityType'] for x in api('GET',f'bundleIds/{bid}/bundleIdCapabilities',params={'limit':200})}
failed=[]
for cap in CAPS:
    if cap in existing: print('EXISTS',cap); continue
    try:
        api('POST','bundleIdCapabilities',{'data':{'type':'bundleIdCapabilities','attributes':{'capabilityType':cap},'relationships':{'bundleId':{'data':rel('bundleIds',bid)}}}})
        print('ENABLED',cap)
    except RuntimeError as e: failed.append(cap); print('MANUAL REQUIRED',cap,e)
if failed: raise SystemExit('Resolve failed capabilities in portal and rerun.')
if a.certificate and a.device:
    if input('Have all manual portal settings been completed? Type YES: ')!='YES': raise SystemExit('Profile creation skipped')
    data=api('POST','profiles',{'data':{'type':'profiles','attributes':{'name':a.profile_name,'profileType':'IOS_APP_DEVELOPMENT'},'relationships':{'bundleId':{'data':rel('bundleIds',bid)},'certificates':{'data':[rel('certificates',a.certificate)]},'devices':{'data':[rel('devices',d) for d in a.device]}}}})
    out=pathlib.Path('AirSIM-generated.mobileprovision')
    out.write_bytes(base64.b64decode(data['attributes']['profileContent']))
    print('Saved',out,'; run --verify on it')
else: print('Profile not created: supply --certificate and --device (API resource IDs), after portal configuration.')
