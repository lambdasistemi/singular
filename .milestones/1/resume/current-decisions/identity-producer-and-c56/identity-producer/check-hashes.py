import hashlib,json
from pathlib import Path
root=Path(__file__).resolve().parent
out=root/'artifacts'
checks={}
for label in ('applied','unapplied'):
 b=(out/(label+'.serialised.cbor')).read_bytes()
 h=(out/(label+'.script-hash.hex')).read_text()
 checks[label]={'ledgerHash':h,'independentV3Hash':hashlib.blake2b(b'\x03'+b,digest_size=28).hexdigest(),'bareHash':hashlib.blake2b(b,digest_size=28).hexdigest()}
 assert checks[label]['ledgerHash']==checks[label]['independentV3Hash']
 assert checks[label]['ledgerHash']!=checks[label]['bareHash']
assert checks['applied']['ledgerHash']!=checks['unapplied']['ledgerHash']
print(json.dumps(checks,indent=2))
