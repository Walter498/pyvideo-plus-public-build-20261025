"""Portable verification of embedded ad-hoc CodeDirectory pages and entitlements.
Not an Apple trust/AMFI or device execution test.
"""
import hashlib,plistlib,struct

def verify_signature(b):
    assert len(b)>=32
    magic,cpu,sub,kind,ncmds,sizeofcmds=struct.unpack_from('<6I',b)
    assert magic==0xfeedfacf and cpu==0x100000c and sub&0xffffff==2
    pos=32;signature=None
    for _ in range(ncmds):
        cmd,size=struct.unpack_from('<II',b,pos)
        assert size>=8 and pos+size<=32+sizeofcmds<=len(b)
        if cmd==0x1d:
            assert signature is None
            signature=struct.unpack_from('<II',b,pos+8)
        pos+=size
    assert pos==32+sizeofcmds and signature is not None,'missing signature'
    off,length=signature
    assert off+length<=len(b)
    magic,total,count=struct.unpack_from('>III',b,off)
    assert magic==0xfade0cc0 and 12+count*8<=total<=length
    blobs={}
    for i in range(count):
        slot,rel=struct.unpack_from('>II',b,off+12+i*8)
        assert slot not in blobs and rel>=12+count*8 and rel+8<=total
        tag,size=struct.unpack_from('>II',b,off+rel)
        assert size>=8 and rel+size<=total
        blobs[slot]=b[off+rel:off+rel+size]
    directories=0
    for slot,cd in blobs.items():
        if struct.unpack_from('>I',cd)[0]!=0xfade0c02:continue
        directories+=1
        _,_,version,flags,hashoff,identoff,nspecial,ncode,limit=struct.unpack_from('>9I',cd)
        hsize,htype,platform,page=struct.unpack_from('4B',cd,36)
        algorithms={1:('sha1',20),2:('sha256',32),3:('sha256',20),4:('sha384',48)}
        assert htype in algorithms and hsize==algorithms[htype][1]
        assert 0<page<=20 and limit==off and ncode==(limit+(1<<page)-1)//(1<<page)
        assert hashoff-nspecial*hsize>=44 and hashoff+ncode*hsize<=len(cd)
        assert 0<identoff<len(cd) and b'\0' in cd[identoff:]
        def digest(data):return hashlib.new(algorithms[htype][0],data).digest()[:hsize]
        for i in range(ncode):
            assert cd[hashoff+i*hsize:hashoff+(i+1)*hsize]==digest(b[i*(1<<page):min((i+1)*(1<<page),limit)]),'code page hash mismatch'
        for special in (5,7):
            if special in blobs:
                assert nspecial>=special
                assert cd[hashoff-special*hsize:hashoff-(special-1)*hsize]==digest(blobs[special]),'entitlements hash mismatch'
    assert directories>0,'missing CodeDirectory'
    ent=plistlib.loads(blobs[5][8:]) if 5 in blobs else {}
    return ent
