#!/usr/bin/env python3
"""Generate the native API explorer from a firmware OpenAPI YAML (requires PyYAML).
Usage: python3 scripts/generate-api-catalog.py path/to/openapi.yaml
The spec should come from http://YOUR_BAR/openapi.yaml, not an unpinned dev API.
"""
import json
from pathlib import Path
import sys
import yaml

spec = yaml.safe_load(Path(sys.argv[1]).read_text())
def resolve(value, depth=0):
    if depth > 80:
        raise ValueError('recursive API schema')
    if isinstance(value, dict):
        if '$ref' in value:
            target = spec
            for part in value['$ref'].removeprefix('#/').split('/'):
                target = target[part]
            return resolve(target, depth+1)
        return {k: resolve(v, depth+1) for k,v in value.items()}
    if isinstance(value,list): return [resolve(v,depth+1) for v in value]
    return value

def example(s):
    for k in ['example','default']:
        if k in s: return s[k]
    if s.get('enum'): return s['enum'][0]
    for k in ['oneOf','anyOf','allOf']:
        if k in s: return example(s[k][0])
    t=s.get('type')
    if t=='object' or 'properties' in s:
        return {k:example(v) for k,v in s.get('properties',{}).items() if k in s.get('required',s.get('properties',{}))}
    if t=='array': return []
    if t in ('integer','number'): return s.get('minimum',0)
    if t=='boolean': return False
    return ''

out=[]
for path, item in spec['paths'].items():
    for method,operation in item.items():
        if method not in ['get','post','put','delete','patch']: continue
        op=resolve({k:v for k,v in operation.items() if k != "responses"})
        op.setdefault('operationId', method + path.replace('/', '_'))
        params=[]
        for p in resolve(item.get('parameters',[]))+op.get('parameters',[]):
            schema=p.get('schema',{})
            params.append(dict(name=p['name'],location=p['in'],required=p.get('required',False),
                detail=p.get('description',''),choices=[str(x) for x in schema.get('enum',[])],
                defaultValue=str(schema.get('default','')).lower() if isinstance(schema.get('default'),bool) else str(schema.get('default',''))))
        content=op.get('requestBody',{}).get('content',{})
        ct=next(iter(content),'')
        schema=content.get(ct,{}).get('schema',{})
        out.append(dict(id=op['operationId'],path=path.removeprefix('/api'),method=method.upper(),
            title=op.get('summary',op['operationId']),detail=op.get('description',''),group=op.get('tags',['Other'])[0],
            parameters=params,contentType=ct,bodyTemplate=json.dumps(example(schema),indent=2) if ct=='application/json' else '',
            bodySchema=json.dumps(schema,indent=2) if schema else ''))
raw=json.dumps(out,separators=(',',':'),ensure_ascii=True)
path=Path('Sources/BarKeep/APICatalog.generated.swift')
path.write_text('// Generated from BUSY Bar OpenAPI '+spec['info']['version']+' by scripts/generate-api-catalog.py.\nimport Foundation\n\nextension DeviceEndpoint {\n    static let apiVersion = '+json.dumps(spec['info']['version'])+'\n    static let all: [DeviceEndpoint] = try! JSONDecoder().decode([DeviceEndpoint].self, from: Data(#"""\n'+raw+'\n"""#.utf8))\n}\n')
print(f'Generated {len(out)} operations from API {spec["info"]["version"]}')
