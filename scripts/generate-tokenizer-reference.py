"""Development-only reference corpus. Requires the pinned official tiktoken 0.14.0."""
import json
from pathlib import Path
import random
import tiktoken

assert tiktoken.__version__ == '0.14.0', 'use tiktoken==0.14.0 in an isolated development environment'
samples = ['', 'Hello, world!', '我们能看出来 MCP 占多少 token？', '日本語のスキルを検証します。',
           'مرحبا بالعالم', 'नमस्ते दुनिया', 'ภาษาไทยทดสอบ', '👩🏽‍💻🚀🇯🇵', 'e\u0301 é a\u200db\ufe0f',
           '\r\n\t  \n', '<|endoftext|> <|endofprompt|>', 'abc\x00def',
           'A' * 10000, ' ' * 10000, '0' * 10000, 'abc def ' * 500]
samples += [json.dumps({'type': 'object', 'properties': {'query': {'type': 'string', 'description': '搜索文档'}}, 'required': ['query']}, ensure_ascii=False)]
rng = random.Random(1701)
alphabet = 'aA09 _-\n\r\t中文日本語éß\u0301\u200d👩🚀{}[]<>/"💻'
for _ in range(250):
    samples.append(''.join(rng.choice(alphabet) for _ in range(rng.randint(1, 160))))
for _ in range(100):
    scalars = [rng.randrange(0x110000) for _ in range(24)]
    samples.append(''.join(chr(value) for value in scalars if not 0xD800 <= value <= 0xDFFF))
rows = []
for name in ['cl100k_base', 'o200k_base']:
    encoder = tiktoken.get_encoding(name)
    for text in samples:
        rows.append({'encoding': name, 'text': text, 'tokens': encoder.encode_ordinary(text)})
file = Path(__file__).resolve().parent.parent / 'Tests/AgentDoctorTests/Fixtures/tokenizer-reference-vectors.json'
file.parent.mkdir(parents=True, exist_ok=True)
file.write_text(json.dumps({'reference': 'tiktoken 0.14.0 encode_ordinary', 'vectors': rows}, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'vectors': len(rows), 'reference': 'tiktoken 0.14.0 encode_ordinary'}))

body = 'Hello, world!\n我们能看出来 MCP 占多少 token？'
text = '---\nname: fixture\ndescription: 验证本地分词\n---\n' + body
tool = {'name': 'fixture', 'description': '搜索文档', 'inputSchema': {'type': 'object'}}
case = {'text': text, 'body': body, 'catalog': 'fixture\n验证本地分词', 'tool': tool, 'reference': 'tiktoken 0.14.0 encode_ordinary', 'encodings': {}}
for name in ['cl100k_base', 'o200k_base']:
    encoder = tiktoken.get_encoding(name)
    count = lambda value: len(encoder.encode_ordinary(value))
    case['encodings'][name] = {'document': count(text), 'body': count(body), 'catalog': count(case['catalog']), 'definition': count(json.dumps(tool, ensure_ascii=False, sort_keys=True, separators=(',', ':')))}
(file.parent / 'tokenizer-cli-reference.json').write_text(json.dumps(case, ensure_ascii=False, indent=2) + '\n')
