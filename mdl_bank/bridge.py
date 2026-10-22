"""Local NWN1 bank editor. No game installation writes; outputs are validated first."""
from pathlib import Path
import sys,json,re,shutil,hashlib,time,os,traceback,subprocess
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'vendor'))
import CompileModels as cm
import stock_resources as tint
import RobePoseAudit as poses

CLIP=re.compile(r'(?im)^[ \t]*newanim[ \t]+(\S+)[ \t]+\S+[^\n]*\n[\s\S]*?^[ \t]*doneanim[^\n]*')
NODE=re.compile(r'(?im)^[ \t]*node[ \t]+(\S+)[ \t]+(\S+)[^\n]*\n([\s\S]*?)^[ \t]*endnode[^\n]*')
SAFE=re.compile(r'^[a-zA-Z0-9_]{1,16}$')

def decode_mdl(data):
    text=data.decode('utf-8-sig') if data.startswith(b'\xef\xbb\xbf') else data.decode('latin1')
    return text.replace('\r\n','\n').replace('\r','\n')

def compiler_run(exe,stage,args,log):
    with (stage/log).open('w',encoding='utf8') as stream:
        result=subprocess.run([str(exe),*map(str,args)],cwd=stage,stdout=stream,stderr=subprocess.STDOUT,timeout=180,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    text=(stage/log).read_text(errors='replace')
    if result.returncode or re.search(r'(?i)(error:|aborted|unable to locate|unable to open)',text):
        raise ValueError('Compiler: '+text[-3000:])

def model_name(text):
    m=re.search(r'(?im)^\s*newmodel\s+(\S+)',text)
    if not m or not SAFE.fullmatch(m[1]): raise ValueError('Expected a full NWN1 model with a valid newmodel name (1–16 characters).')
    return m[1]

def list_clips(text):
    result=[];seen=set()
    for m in CLIP.finditer(text):
        name=m[1].lower()
        if name in seen: raise ValueError('Duplicate animation name: '+name)
        seen.add(name)
        length=re.search(r'(?im)^\s*length\s+(\S+)',m[0])
        if not length: raise ValueError('Animation has no length: '+name)
        result.append({'name':name,'length':float(length[1]),'events':len(re.findall(r'(?im)^\s*event\s',m[0]))})
    return result

def decompile(data,stage,name):
    (stage/'raw').mkdir(exist_ok=True);(stage/'ascii').mkdir(exist_ok=True)
    exe,_=cm.prepare_compiler(stage)
    src=stage/'raw'/f'{name}.mdl';src.write_bytes(data)
    compiler_run(exe,stage,['-de',src,str(stage/'ascii')+'/'],'decompile.log')
    text=(stage/'ascii'/f'{name}.mdl').read_text(encoding='latin1')
    return poses.accurate_rotations(text,data)

def write_json(path,value):
    path.write_text(json.dumps(value,indent=2,ensure_ascii=False),encoding='utf8')

def open_bank(req):
    source=Path(req['source']).resolve();session=Path(req['session']).resolve()
    session.mkdir(parents=True,exist_ok=False)
    data=source.read_bytes()
    (session/'original.mdl').write_bytes(data)
    if cm.binary(data):
        text=decompile(data,session,source.stem)
    else: text=decode_mdl(data)
    name=model_name(text);clips=list_clips(text)
    if not clips: raise ValueError('This model contains no local animations. Open its animation supermodel instead: '+(cm.supermodel(data) or 'none'))
    (session/'working.mdl').write_text(text,encoding='latin1')
    state={'model':name,'source':str(source),'source_sha256':cm.digest(data),'binary':cm.binary(data),'supermodel':cm.supermodel(data),'changed':[]}
    write_json(session/'state.json',state)
    return {**state,'clips':clips,'session':str(session)}

def preview_rig(text):
    # Standard NWN humanoid bank families, including custom banks inheriting them.
    match=re.search(r'(?im)^\s*setsupermodel\s+\S+\s+(\S+)',text)
    parent=match[1].lower() if match else ''
    for family,rig in [('fa','female'),('ba','male')]:
        if re.fullmatch(r'(?:an_)?a_'+family+r'(?:_\w+)?',parent): return rig
    name=model_name(text).lower()
    if name in ('a_fa','a_ba'): return 'female' if name=='a_fa' else 'male'
    return ''

def preview_clip(req):
    session=Path(req['session']).resolve();text=(session/'working.mdl').read_text(encoding='latin1')
    match=next((m for m in CLIP.finditer(text) if m[1].lower()==req['animation'].lower()),None)
    if match is None: raise ValueError('Animation not found')
    # Apply local geometry defaults when the selected clip has no channel for a node.
    clip=match[0];existing={m[2].lower():m for m in NODE.finditer(clip)}
    extra=[]
    for kind,name,props in cm.parse_nodes(text.split('endmodelgeom',1)[0]):
        defaults=[];current=existing.get(name)
        for key in ['orientation','position']:
            if key in props and not (current and re.search(r'(?im)^\s*'+key+r'(?:key|bezierkey)?\s',current[0])):
                defaults.append('  '+key+' '+' '.join(props[key])+'\n')
        if not defaults: continue
        if current:
            original=current[0];changed=re.sub(r'(?im)^([ \t]*endnode)',lambda m:''.join(defaults)+m[1],original)
            clip=clip.replace(original,changed,1)
        else: extra.append(f'node {kind} {name}\n  parent '+ ' '.join(props.get('parent',['NULL']))+'\n'+''.join(defaults)+'endnode\n')
    clip=re.sub(r'(?im)^([ \t]*doneanim)',lambda m:''.join(extra)+m[1],clip)
    node_names={m[2].lower() for m in NODE.finditer(clip)}
    if not {'rootdummy','torso_g'}.issubset(node_names):
        raise ValueError('This preview supports the NWN humanoid skeleton (rootdummy / torso_g). This model needs a different preview rig.')
    out=session/'selected.txt';out.write_text(clip,encoding='utf8')
    return {'preview':str(out),'animation':req['animation'],'rig':preview_rig(text)}

def channel_pattern(channel):
    # Counted and endlist arrays. Keep all unrelated properties, events and nodes intact.
    return re.compile(r'(?im)^[ \t]*'+channel+r'(?:bezierkey|key)[ \t]*(\d*)[ \t]*\n')

def remove_channel(body,channel):
    p=channel_pattern(channel)
    while (m:=p.search(body)):
        if m[1]:
            tail=body[m.end():].splitlines(keepends=True);end=m.end()+sum(map(len,tail[:int(m[1])]))
        else:
            endlist=re.search(r'(?im)^[ \t]*endlist[^\n]*(?:\n|$)',body[m.end():])
            if not endlist: raise ValueError('Unterminated '+channel+'key')
            end=m.end()+endlist.end()
        body=body[:m.start()]+body[end:]
    return re.sub(r'(?im)^[ \t]*'+channel+r'[ \t]+[^\n]*\n?','',body)

def get_channel(body,channel):
    m=channel_pattern(channel).search(body)
    if not m: return ''
    if m[1]:
        tail=body[m.end():].splitlines(keepends=True);end=m.end()+sum(map(len,tail[:int(m[1])]))
    else:
        e=re.search(r'(?im)^[ \t]*endlist[^\n]*(?:\n|$)',body[m.end():]);end=m.end()+e.end()
    return body[m.start():end]

def retime_tracks(text,ratio):
    lines=text.splitlines(keepends=True);remaining=0;unbounded=False
    for i,line in enumerate(lines):
        header=re.match(r'^\s*\w+(?:bezierkey|key)\s*(\d*)\s*$',line)
        if header:
            remaining=int(header[1]) if header[1] else 0;unbounded=not header[1];continue
        if line.strip().lower()=='endlist':unbounded=False;remaining=0;continue
        if remaining or unbounded:
            numeric=re.match(r'^(\s*)([-+\d.eE]+)(\s+.*)$',line)
            if numeric:
                ending='\n' if line.endswith('\n') else ''
                lines[i]=numeric[1]+format(float(numeric[2])*ratio,'.9g')+numeric[3].rstrip('\n')+ending
                if remaining:remaining-=1
    return ''.join(lines)

def stage_clip(req):
    session=Path(req['session']).resolve();text=(session/'working.mdl').read_text(encoding='latin1')
    generated=Path(req['edited']).read_text(encoding='utf8');baseline=Path(req['baseline']).read_text(encoding='utf8')
    selected=req['animation'].lower();match=next(m for m in CLIP.finditer(text) if m[1].lower()==selected)
    if generated==baseline:
        return {'animation':selected,'changed_nodes':[],'clips':list_clips(text)}
    old=match[0];new=old
    length=float(re.search(r'(?im)^\s*length\s+(\S+)',generated)[1]);old_length=float(re.search(r'(?im)^\s*length\s+(\S+)',old)[1])
    if length<=0: raise ValueError('Animation duration must be positive')
    if length!=old_length: new=retime_tracks(old,length/old_length if old_length else 1)
    originals={m[2].lower():m for m in NODE.finditer(new)}
    before={m[2].lower():m for m in NODE.finditer(baseline)}
    additions=[];changed=[]
    for m in NODE.finditer(generated):
        name=m[2].lower();replacements={}
        for channel in ['orientation','position']:
            value=get_channel(m[3],channel)
            prior=get_channel(before[name][3],channel) if name in before else ''
            if value and value.split()!=prior.split(): replacements[channel]=value
        if not replacements: continue
        if name in originals:
            original=originals[name];body=original[3]
            for channel,value in replacements.items(): body=remove_channel(body,channel)+'\n'+value
            node=f'node {original[1]} {original[2]}\n'+body+'endnode'
            new=new.replace(original[0],node,1)
        else:
            parent=re.search(r'(?im)^\s*parent\s+(\S+)',m[3])[1]
            if parent=='a_ba_non_combat':parent=model_name(text)
            additions.append(f'node {m[1]} {m[2]}\n  parent {parent}\n'+''.join(replacements.values())+'endnode\n')
        changed.append(name)
    new=re.sub(r'(?im)^([ \t]*length[ \t]+)\S+',lambda m:m[1]+format(length,'.9g'),new)
    if length!=old_length:
        # Preserve event phase when the editor changes the overall duration.
        ratio=length/old_length if old_length else 1
        new=re.sub(r'(?im)^([ \t]*event[ \t]+)(\S+)',lambda m:m[1]+format(float(m[2])*ratio,'.9g'),new)
    new=re.sub(r'(?im)^([ \t]*doneanim)',lambda m:''.join(additions)+m[1],new)
    if new!=old:
        text=text[:match.start()]+new+text[match.end():]
        (session/'working.mdl').write_text(text,encoding='latin1')
        state=json.loads((session/'state.json').read_text(encoding='utf8'))
        state['changed']=sorted(set(state['changed']+[selected]));write_json(session/'state.json',state)
    return {'animation':selected,'changed_nodes':changed,'clips':list_clips(text)}

def dependencies(text,source,req,stage):
    pending=[cm.supermodel(text.encode('latin1'))];found={};stock=None
    while pending:
        name=pending.pop()
        if not name or name in found:continue
        if not SAFE.fullmatch(name): raise ValueError('Invalid supermodel name: '+name)
        if name.lower()==model_name(text).lower(): raise ValueError('Cyclic supermodel dependency: '+name)
        candidates=[source.parent/f'{name}.mdl']
        if req.get('dependencies'): candidates.append(Path(req['dependencies'])/f'{name}.mdl')
        path=next((p for p in candidates if p.is_file()),None)
        if path:data=path.read_bytes()
        else:
            if not req.get('game_data'): raise ValueError('Missing supermodel '+name+'.mdl. Configure Dependencies or NWN game data in Workshop settings.')
            if stock is None:stock=tint.read_stock_key_models(Path(req['game_data']))
            if name not in stock:raise ValueError('Missing supermodel: '+name+'.mdl. Choose its folder under Dependencies.')
            data=tint.extract_stock_bif_resource(*stock[name])
        found[name]=data;(stage/(name+'.mdl')).write_bytes(data)
        pending.append(cm.supermodel(data))
    return sorted(found)

def import_references(req):
    if not req.get('game_data'): raise ValueError('Choose your NWN game data folder in Workshop settings.')
    output=Path(req['output']).resolve();output.mkdir(parents=True,exist_ok=True)
    stock=tint.read_stock_key_models(Path(req['game_data']))
    stage=output/('import-'+str(time.time_ns()));stage.mkdir()
    files=[]
    for name in ['a_ba','a_ba_med_weap','a_ba_non_combat']:
        if name not in stock: continue
        sub=stage/name;sub.mkdir()
        text=decompile(tint.extract_stock_bif_resource(*stock[name]),sub,name)
        for match in CLIP.finditer(text):
            clip=match[1].lower()
            if not (clip.startswith('2h') or 'ready' in clip or clip in ['pause1','pause2','drwright']):continue
            target=output/(name+'__'+clip+'.txt')
            target.write_text(match[0],encoding='utf8')
            files.append(str(target))
    if not files: raise ValueError('No humanoid references found in this installation.')
    return {'files':files,'output':str(output),'idle':str(output/'a_ba__pause1.txt')}

def event_inventory(text):
    return [[m[1].lower(),[[float(e[0]),e[1].strip().lower()] for e in re.findall(r'(?im)^\s*event\s+(\S+)\s+([^\n]+)',m[0])]] for m in CLIP.finditer(text)]

def export_bank(req):
    session=Path(req['session']).resolve();state=json.loads((session/'state.json').read_text(encoding='utf8'))
    source=Path(state['source']);output=Path(req['output']).resolve()
    if output.suffix.lower()!='.mdl':raise ValueError('Export filename must end in .mdl')
    text=(session/'working.mdl').read_text(encoding='latin1');name=model_name(text)
    if output.stem.lower()!=name.lower():raise ValueError('Keep the original model filename '+name+'.mdl. Choose another folder for a separate copy.')
    stage=session/('compile-'+str(time.time_ns()));stage.mkdir()
    for folder in ['input','binary','verify']:(stage/folder).mkdir()
    deps=dependencies(text,source,req,stage)
    exe,_=cm.prepare_compiler(stage)
    original_source=text.encode('latin1');prepared=cm.protect_vertex_identity(original_source)
    (stage/'input'/f'{name}.mdl').write_bytes(prepared)
    compiler_run(exe,stage,['-cne',stage/'input'/f'{name}.mdl',str(stage/'binary')+'/'],'compile.log')
    binary_path=stage/'binary'/f'{name}.mdl'
    compiled=poses.repair_compiler_skin_bindings(cm.restore_vertex_attributes(original_source,binary_path.read_bytes()))
    binary_path.write_bytes(compiled)
    compiler_run(exe,stage,['-de',binary_path,str(stage/'verify')+'/'],'verify.log')
    back=(stage/'verify'/f'{name}.mdl').read_text(encoding='latin1')
    cm.validate_round_trip(original_source,compiled,back)
    if not cm.equivalent([[x['name'],x['length']] for x in list_clips(text)],[[x['name'],x['length']] for x in list_clips(back)]):raise ValueError('Animation inventory or duration changed during compilation')
    if not cm.equivalent(event_inventory(text),event_inventory(back)):raise ValueError('Animation events changed during compilation')
    # Verify the edited source retains every unedited animation verbatim.
    original=(session/'original.mdl').read_bytes()
    if cm.binary(original): original_text=poses.accurate_rotations((session/'ascii'/f'{source.stem}.mdl').read_text(encoding='latin1'),original)
    else:original_text=decode_mdl(original)
    original_clips={m[1].lower():m[0] for m in CLIP.finditer(original_text)}
    for m in CLIP.finditer(text):
        if m[1].lower() not in state['changed'] and original_clips[m[1].lower()]!=m[0]:raise ValueError('Unexpected change to unedited clip '+m[1])
    output.parent.mkdir(parents=True,exist_ok=True)
    backup=None
    if output.exists():
        backup=output.with_name(output.name+'.backup-'+str(time.time_ns()));shutil.copy2(output,backup)
    temp=output.with_name(output.name+'.tmp-'+str(time.time_ns()));temp.write_bytes(compiled);os.replace(temp,output)
    output.with_suffix('.mdl.ascii').write_bytes(original_source)
    report={'output':str(output),'sha256':cm.digest(compiled),'model':name,'animations':len(list_clips(back)),'changed':state['changed'],'dependencies':deps,'validated':True,'backup':str(backup) if backup else None}
    write_json(output.with_suffix('.mdl.report.json'),report)
    return report

def dispatch(req):
    cm.COMPILER_PATH=req.get('compiler')
    if not cm.COMPILER_PATH or not Path(cm.COMPILER_PATH).is_file(): raise ValueError('Configure the supported nwnmdlcomp executable in Workshop settings.')
    return {'references':import_references,'open':open_bank,'preview':preview_clip,'stage':stage_clip,'export':export_bank}[req['action']](req)

if __name__=='__main__':
    request=Path(sys.argv[1]);response=Path(sys.argv[2])
    try: result={'ok':True,**dispatch(json.loads(request.read_text(encoding='utf8')))}
    except Exception as e: result={'ok':False,'error':str(e)};traceback.print_exc()
    write_json(response,result)
    sys.exit(0 if result['ok'] else 1)
