#!/usr/bin/env python3
"""Generate APNs/VoIP CSRs and export Apple-issued certificates as PKCS#12."""
import os, re, subprocess, pathlib, getpass, sys
os.umask(0o077)
def run(*args, **kw):
    return subprocess.run(['openssl', *map(str,args)], check=True, **kw)
def ask_bundle():
    b=input('Bundle ID: ').strip()
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',b):
        raise SystemExit('Invalid Bundle ID')
    return b
def main():
    b=ask_bundle()
    root=pathlib.Path.home()/'.airsim-push'/b
    root.mkdir(parents=True,exist_ok=True,mode=0o700)
    print('1: APNs CSR  2: VoIP CSR  3: Both CSRs  4: Import CER and export P12')
    choice=input('Select: ').strip()
    if choice in ('1','2','3'):
        for kind in {'1':['apns'],'2':['voip'],'3':['apns','voip']}[choice]:
            d=root/kind; d.mkdir(exist_ok=True,mode=0o700)
            key=d/'private.key'; csr=d/'request.csr'
            if key.exists() or csr.exists():
                print('Existing files preserved:',d); continue
            run('genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:2048','-out',key)
            run('req','-new','-key',key,'-subj',f'/CN={b} {kind}','-out',csr)
            print('Upload CSR:',csr)
        print('Portal: https://developer.apple.com/account/resources/certificates/add')
        print('Select Apple Push Notification service SSL (Sandbox & Production) or VoIP Services Certificate, select the same App ID, upload matching CSR, download CER.')
        return
    if choice!='4': raise SystemExit('Invalid selection')
    kind=input('Certificate type (apns/voip): ').strip()
    if kind not in ('apns','voip'): raise SystemExit('Invalid type')
    d=root/kind; key=d/'private.key'
    if not key.is_file(): raise SystemExit('Original private key missing')
    cer=pathlib.Path(input('Downloaded CER path: ').strip()).expanduser()
    if not cer.is_file(): raise SystemExit('CER not found')
    pem=d/'certificate.pem'; out=d/(kind+'.p12')
    if pem.exists() or out.exists(): raise SystemExit('Output exists; preserve or move it before retrying')
    import tempfile
    with tempfile.TemporaryDirectory(dir=d) as tmp:
        cert=pathlib.Path(tmp)/'cert.pem'
        try: run('x509','-inform','DER','-in',cer,'-out',cert,stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError: run('x509','-in',cer,'-out',cert)
        pub1=run('x509','-in',cert,'-pubkey','-noout',stdout=subprocess.PIPE).stdout
        pub2=run('pkey','-in',key,'-pubout',stdout=subprocess.PIPE).stdout
        if pub1.strip()!=pub2.strip(): raise SystemExit('Certificate/private key mismatch')
        run('x509','-in',cert,'-checkend','0','-noout')
        run('x509','-in',cert,'-noout','-subject','-issuer','-dates','-text')
        print('Check certificate type, Bundle ID and APNs topic extensions above. VoIP and Live Activity topics are not inferred from filenames.')
        if input('Confirm certificate identity and topics (YES): ')!='YES': raise SystemExit('Cancelled')
        password=getpass.getpass('New P12 password: ')
        if not password or '\n' in password or '\r' in password or password!=getpass.getpass('Repeat password: '): raise SystemExit('Invalid or mismatched password')
        tempout=pathlib.Path(tmp)/'export.p12'
        run('pkcs12','-export','-inkey',key,'-in',cert,'-name',b+' '+kind,'-out',tempout,'-passout','stdin',input=(password+'\n').encode())
        run('pkcs12','-in',tempout,'-info','-noout','-passin','stdin',input=(password+'\n').encode())
        pem.write_bytes(cert.read_bytes()); out.write_bytes(tempout.read_bytes())
    print('P12 saved:',out)
    print('Key match and expiration checked; Apple trust chain and live push delivery not tested.')
if __name__=='__main__':
    try: main()
    except (KeyboardInterrupt,EOFError): sys.exit('Cancelled')
    except subprocess.CalledProcessError as e: sys.exit(f'OpenSSL failed: {e.returncode}')
