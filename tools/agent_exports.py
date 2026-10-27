"""Bounded export-trie edit for the hash-pinned original Agent only.
No executable code or architecture conversion; alias exposes its existing mutex.
"""
from __future__ import annotations
import hashlib,struct
BASE_SHA='eb3cb70ba332473bb1f294cd091142959f37a6465dabb6c88b33db41e017a623'
MUTEX_REL=0x263500
ALIAS='_PVXAgentRemuxMutex'

def uleb(n):
    out=bytearray()
    while n>127: out.append((n&127)|128);n>>=7
    out.append(n);return bytes(out)
def read_uleb(data,pos):
    n=shift=0
    for _ in range(10):
        b=data[pos];pos+=1;n|=(b&127)<<shift
        if not b&128:return n,pos
        shift+=7
    raise ValueError('invalid uleb')
def exports(data):
    out={};seen=set()
    def walk(pos,name,depth):
        if depth>2048 or (pos,name) in seen:raise ValueError('cyclic export trie')
        seen.add((pos,name));size,p=read_uleb(data,pos)
        if size:out[name]=data[p:p+size]
        p+=size;count=data[p];p+=1
        for _ in range(count):
            end=data.index(0,p);label=data[p:end].decode('utf8');off,p=read_uleb(data,end+1)
            walk(off,name+label,depth+1)
    walk(0,'',0);return out

def encode_exports(items):
    root={'term':b'','children':{}}
    for name,term in sorted(items.items()):
        node=root
        for c in name:node=node['children'].setdefault(c,{'term':b'','children':{}})
        node['term']=term
    nodes=[]
    def flatten(node):
        node['edges']=[];nodes.append(node)
        for label,child in node['children'].items():
            while not child['term'] and len(child['children'])==1:
                char,nextchild=next(iter(child['children'].items()));label+=char;child=nextchild
            node['edges'].append((label.encode()+b'\0',child));flatten(child)
    flatten(root)
    offsets={id(n):0 for n in nodes}
    for _ in range(30):
        encoded=[];new={};pos=0
        for n in nodes:
            new[id(n)]=pos
            b=uleb(len(n['term']))+n['term']+bytes([len(n['edges'])])
            for label,child in n['edges']:b+=label+uleb(offsets[id(child)])
            encoded.append(b);pos+=len(b)
        if new==offsets:return b''.join(encoded)
        offsets=new
    raise ValueError('export offset convergence failed')

def expose_mutex(binary,original):
    if hashlib.sha256(original).hexdigest()!=BASE_SHA:raise ValueError('unrecognized Agent baseline')
    # Original caller: ADRP x0, page; ADD x0,#0x500; BL pthread_mutex_trylock.
    assert original[0x1a30d4:0x1a30dc]==bytes.fromhex('0006009000001491')
    b=bytearray(binary);count=struct.unpack_from('<I',b,16)[0];pos=32
    exp=sig=linkedit=symtab=None;segments=[]
    for _ in range(count):
        cmd,size=struct.unpack_from('<II',b,pos)
        if cmd==0x80000033:exp=pos
        if cmd==0x1d:sig=pos
        if cmd==0x2:symtab=pos
        if cmd==0x19:
            name=bytes(b[pos+8:pos+24]).rstrip(b'\0')
            vm,vs,fo,fs=struct.unpack_from('<QQQQ',b,pos+24);segments.append((name,vm,vs))
            if name==b'__LINKEDIT':linkedit=pos
        pos+=size
    assert exp and sig and linkedit and symtab
    assert any(name in (b'__DATA',b'__DATA_DIRTY') and vm<=0x100000000+MUTEX_REL<vm+vs for name,vm,vs in segments)
    off,size=struct.unpack_from('<II',b,exp+8);old=exports(bytes(b[off:off+size]))
    assert ALIAS not in old
    new=dict(old);new[ALIAS]=uleb(0)+uleb(MUTEX_REL)
    trie=encode_exports(new);assert exports(trie)==new
    # Keep every existing offset intact. Relocate the string table after the
    # new trie: ldid computes signature placement using the string table end.
    stroff,strsize=struct.unpack_from('<II',b,symtab+16)
    strings=bytes(b[stroff:stroff+strsize])
    sigoff,sigsize=struct.unpack_from('<II',b,sig+8)
    assert sigoff+sigsize==len(b)
    del b[sigoff:];b.extend(bytes((-len(b))%8));new_off=len(b);b.extend(trie)
    b.extend(bytes((-len(b))%8));new_stroff=len(b);b.extend(strings)
    struct.pack_into('<II',b,symtab+16,new_stroff,strsize)
    struct.pack_into('<II',b,exp+8,new_off,len(trie))
    struct.pack_into('<II',b,sig+8,len(b),0)
    lo=struct.unpack_from('<Q',b,linkedit+40)[0]
    struct.pack_into('<Q',b,linkedit+48,len(b)-lo)
    struct.pack_into('<Q',b,linkedit+32,(len(b)-lo+0x3fff)&~0x3fff)
    return bytes(b),{'alias':ALIAS,'relativeAddress':hex(MUTEX_REL),'originalExports':len(old),'exportsPreserved':True,'newTrieSize':len(trie)}

def export_map(binary):
    count=struct.unpack_from('<I',binary,16)[0];pos=32
    for _ in range(count):
        cmd,size=struct.unpack_from('<II',binary,pos)
        if cmd==0x80000033:
            off,n=struct.unpack_from('<II',binary,pos+8)
            if off+n>len(binary):raise ValueError('export trie outside file after signing')
            return exports(binary[off:off+n])
        pos+=size
    raise ValueError('no export trie')

def verify_signed_contract(binary,original):
    before=export_map(original);after=export_map(binary)
    assert after.get(ALIAS)==uleb(0)+uleb(MUTEX_REL),'missing or incorrect shared mutex alias'
    assert all(after.get(name)==terminal for name,terminal in before.items()),'original export changed'
    assert len(after)==len(before)+1,'unexpected export changes'
    assert binary[4:12]==original[4:12],'CPU architecture changed'
    assert binary[0x4000:0x197fac]==original[0x4000:0x197fac],'executable code changed'
    assert binary[0x197fb0:0x234000]==original[0x197fb0:0x234000],'native remux code changed'
    return {'exportsVerifiedAfterSigning':True,'originalExportCount':len(before),'architecturePreserved':True}
