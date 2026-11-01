# Written by AI on 2026.11.01 by model gpt-6.1-sol.
# Provisioning only: does not launch code or create a certificate.
from pathlib import Path
import argparse
import os, subprocess
parser=argparse.ArgumentParser(description='Ask Xcode to manage the isolated test identity with the existing Apple Development identity.')
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parent/'signing'
output=args.output.resolve()
output.mkdir(parents=True,exist_ok=True)
release=Path.home()/'.config/opentrawl/release'
arguments=['/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild','-project',str(root/'Signing.xcodeproj'),'-scheme','Signing','-configuration','Release','-destination','platform=macOS,arch=arm64','-derivedDataPath',str(output/'DerivedData'),'-allowProvisioningUpdates','-authenticationKeyPath',str(release/'app-store-connect-api-key.p8'),'-authenticationKeyID',(release/'app-store-connect-key-id').read_text().strip(),'-authenticationKeyIssuerID',(release/'app-store-connect-issuer-id').read_text().strip(),'CODE_SIGN_IDENTITY=Apple Development','OTHER_CODE_SIGN_FLAGS=--timestamp','build']
before = subprocess.check_output(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
if before.count(b'Apple Development:') != 1:
    raise SystemExit('Expected one existing Apple Development identity. Do not create a certificate for this test.')
with (output/'profile-request.log').open('w') as log:
    result=subprocess.run(arguments,stdout=log,stderr=subprocess.STDOUT,env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode-beta.app/Contents/Developer'))
after = subprocess.check_output(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
if before != after:
    raise SystemExit('Signing identities changed during provisioning. Stop and inspect before proceeding.')
print('Xcode status:', result.returncode)

raise SystemExit(result.returncode)
