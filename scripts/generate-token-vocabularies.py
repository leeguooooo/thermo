"""Build-time generator; production counters never download tables."""
import pathlib,json,base64,zlib,struct,hashlib,urllib.request,argparse
root=pathlib.Path(__file__).resolve().parent.parent
args=argparse.ArgumentParser(description="Regenerate embedded, hash-pinned public token vocabularies; no user text is read.")
args.add_argument('--tables',type=pathlib.Path,help='directory containing cl100k_base and o200k_base table files')
args.add_argument('--download',action='store_true',help='download only official tables and verify pinned hashes')
args=args.parse_args()
metadata_source=json.loads((root/'Resources/TokenVocabularyProvenance.json').read_text())
profiles={item['name']:item for item in metadata_source['tables']}
assert list(profiles)==['cl100k_base','o200k_base']
folder=root/'Sources/CTokenData';(folder/'include').mkdir(parents=True,exist_ok=True)
(folder/'include/CTokenData.h').write_text('#include <stddef.h>\n#include <stdint.h>\nconst char *thermo_token_data(int encoding);\nsize_t thermo_token_uncompressed_size(int encoding);\nint thermo_token_inflate(const uint8_t *src, size_t count, uint8_t *out, size_t *length);\n')
parts=['// Generated from pinned OpenAI tiktoken vocabulary tables; do not edit by hand.\n#include "CTokenData.h"\n#include <zlib.h>\n']
metadata=[]
for index,(name,info) in enumerate(profiles.items()):
 if args.tables:
  raw=(args.tables/name).read_bytes()
 elif args.download:
  raw=urllib.request.urlopen('https://openaipublic.blob.core.windows.net/encodings/'+name+'.tiktoken',timeout=30).read(8_388_609)
 else: raise SystemExit('Specify --tables DIR or explicitly opt into --download')
 assert len(raw)<=8_388_608 and hashlib.sha256(raw).hexdigest()==info['sha256'], 'upstream table hash mismatch'
 entries=[]
 for line in raw.splitlines():
  word,rank=line.split(); word=base64.b64decode(word);entries.append((int(rank),word))
 data=b'TTB1'+struct.pack('<I',len(entries))+b''.join(struct.pack('<IH',rank,len(word))+word for rank,word in entries)
 compressed=base64.b64encode(zlib.compress(data,9)).decode()
 parts.append('static const char table_'+str(index)+'[] =\n'+''.join('"'+compressed[n:n+120]+'"\n' for n in range(0,len(compressed),120))+';\n')
 metadata.append({'name':name,**info,'binarySHA256':hashlib.sha256(data).hexdigest(),'uncompressedBytes':len(data),'base64Bytes':len(compressed)})
parts.append('const char *thermo_token_data(int encoding) { return encoding == 0 ? table_0 : encoding == 1 ? table_1 : 0; }\n')
parts.append('size_t thermo_token_uncompressed_size(int encoding) { return encoding == 0 ? '+str(metadata[0]['uncompressedBytes'])+' : encoding == 1 ? '+str(metadata[1]['uncompressedBytes'])+' : 0; }\n')
parts.append('int thermo_token_inflate(const uint8_t *src, size_t count, uint8_t *out, size_t *length) { uLongf size = *length; int result = uncompress(out, &size, src, count); *length = size; return result; }\n')
(folder/'TokenData.c').write_text(''.join(parts))
(root/'Resources/TokenVocabularyProvenance.json').write_text(json.dumps({'source':'OpenAI tiktoken','referenceVersion':'0.14.0','mode':'ordinary','tables':metadata},indent=2)+'\n')
swift='import Foundation\n\n// Official ordinary-text pre-tokenization rules, pinned to tiktoken 0.14.0.\n'+'enum TokenVocabulary {\n'
for index,table in enumerate(metadata):
 key='cl100k' if index==0 else 'o200k'
 swift+='    static let '+key+'Pattern = #"'+table['pattern']+'"#\n'
 swift+='    static let '+key+'Hash = "'+table['binarySHA256']+'"\n'
swift+='}\n'
(root/'Sources/AgentDoctor/TokenVocabulary.swift').write_text(swift)
print(json.dumps({table['name']:table['binarySHA256'] for table in metadata}))
