// CROWN-2 research harness. Own container and controls; no libbsc implementation.
#include "core.hpp"
#include "baseline.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#include <unistd.h>

namespace fs = std::filesystem;
using Bytes = std::vector<unsigned char>;
static constexpr std::array<unsigned, 5> Ks{1,4,8,16,32};
static constexpr uint32_t Limit = 1u << 24;
static void need(bool ok, const std::string& why) { if (!ok) throw std::runtime_error(why); }
static Bytes read(const fs::path& p) {
    auto size=fs::file_size(p); need(size<=Limit+4096,"file exceeds prototype bound");
    Bytes b(static_cast<size_t>(size)); std::ifstream f(p,std::ios::binary);
    need(bool(f),"open input"); f.read(reinterpret_cast<char*>(b.data()),b.size());
    need(bool(f)||b.empty(),"short input"); return b;
}
static void write(const fs::path& p,const Bytes& b) {
    need(!fs::exists(p),"refuse overwrite: "+p.string());
    std::ofstream f(p,std::ios::binary); need(bool(f),"open output");
    f.write(reinterpret_cast<const char*>(b.data()),b.size()); need(bool(f),"write output");
}
static uint32_t crc32(const Bytes& a,size_t end) {
    uint32_t x=~uint32_t(0);
    for(size_t i=0;i<end;i++) { x^=a[i]; for(unsigned j=0;j<8;j++) x=(x>>1)^(0xedb88320u&(0u-(x&1u))); }
    return ~x;
}
static void u32(Bytes& b,uint32_t x) { for(unsigned i=0;i<4;i++) b.push_back(static_cast<unsigned char>(x>>(8*i))); }
static uint32_t get(const Bytes& b,size_t p) {
    need(p<=b.size()&&b.size()-p>=4,"short integer");
    uint32_t x=0;for(unsigned i=0;i<4;i++) x|=uint32_t(b[p+i])<<(8*i);return x;
}
static void set(Bytes& b,size_t p,uint32_t x) {need(p<=b.size()&&b.size()-p>=4,"set integer");for(unsigned i=0;i<4;i++)b[p+i]=static_cast<unsigned char>(x>>(8*i));}
struct Packet {
    uint32_t kind=0,n=0,k=1,primary=0;
    Bytes bwt;std::vector<uint32_t> starts;
};
static bool valid(const Packet& p) {
    if(p.kind>1||p.n>=Limit||p.bwt.size()!=p.n)return false;
    if(p.kind==0) {
        if(std::find(Ks.begin(),Ks.end(),p.k)==Ks.end())return false;
        if(p.starts.size()!=std::min(p.k,p.n))return false;
        if(p.n==0)return p.primary==0;
        if(p.primary==0||p.primary>p.n||p.starts[0]!=p.primary)return false;
        for(auto i:p.starts)if(i==0||i>p.n)return false;
    } else {
        if(p.n==0||p.starts.size()>255||p.primary==0||p.primary>p.n)return false;
        for(auto i:p.starts)if(i>=p.n)return false;
    }
    return true;
}
static Bytes pack(const Packet& p) {
    need(valid(p),"invalid packet to serialize");
    Bytes b{'C','R','N','2','B','W','T','1'};
    u32(b,p.kind);u32(b,p.n);u32(b,p.k);u32(b,p.primary);u32(b,static_cast<uint32_t>(p.starts.size()));
    for(auto i:p.starts)u32(b,i);
    b.insert(b.end(),p.bwt.begin(),p.bwt.end());u32(b,crc32(b,b.size()));return b;
}
static bool unpack(const Bytes& b,Packet& p) {
    const Bytes magic{'C','R','N','2','B','W','T','1'};
    if(b.size()<32||!std::equal(magic.begin(),magic.end(),b.begin()))return false;
    uint32_t kind=get(b,8),n=get(b,12),k=get(b,16),primary=get(b,20),count=get(b,24);
    if(kind>1||n>=Limit||count>255)return false;
    size_t expected=32u+size_t(n)+4u*size_t(count);
    if(b.size()!=expected||crc32(b,b.size()-4)!=get(b,b.size()-4))return false;
    Packet q;q.kind=kind;q.n=n;q.k=k;q.primary=primary;
    q.starts.reserve(count);for(uint32_t i=0;i<count;i++)q.starts.push_back(get(b,28+4u*i));
    q.bwt.assign(b.begin()+28+4u*count,b.end()-4);
    if(!valid(q))return false;p=std::move(q);return true;
}
static Packet own(const Bytes& input,unsigned k) {
    crown2::Image im;std::string error;need(crown2::encode(input,k,im,error),"encode: "+error);
    Packet p;p.kind=0;p.n=im.n;p.k=im.requested_k;p.primary=im.primary;p.bwt=std::move(im.bwt);p.starts=std::move(im.starts);return p;
}
static crown2::Image image(const Packet& p) {
    crown2::Image im;im.n=p.n;im.primary=p.primary;im.requested_k=p.k;im.bwt=p.bwt;im.starts=p.starts;return im;
}
static Packet reference(const Bytes& input) {
    crown2::BaselineImage im;std::string error;need(crown2::baseline_encode(input,im,error),"baseline encode: "+error);
    Packet p;p.kind=1;p.n=static_cast<uint32_t>(input.size());p.k=0;p.primary=static_cast<uint32_t>(im.primary);p.bwt=std::move(im.bwt);
    for(int i:im.indexes){need(i>=0,"negative reference index");p.starts.push_back(static_cast<uint32_t>(i));}return p;
}
static crown2::BaselineImage reference_image(const Packet& p) {
    crown2::BaselineImage im;im.bwt=p.bwt;im.primary=static_cast<int>(p.primary);
    for(auto i:p.starts)im.indexes.push_back(static_cast<int>(i));return im;
}
static Bytes verify(const Bytes& input,const Packet& p) {
    Packet parsed;auto bytes=pack(p);need(unpack(bytes,parsed),"parse own serialized packet");
    Bytes out;std::string error;
    if(p.kind==0) {
        auto im=image(parsed);
        for(bool pf:{false,true}){need(crown2::decode(im,pf,out,error),"inverse: "+error);need(out==input,"inverse byte mismatch");}
    } else { auto im=reference_image(parsed);need(crown2::baseline_decode(im,out,error),"baseline inverse: "+error);need(out==input,"baseline byte mismatch"); }
    for(size_t pos:std::array<size_t,4>{0,12,bytes.size()/2,bytes.size()-1}) {
        auto corrupt=bytes;corrupt[pos]^=0x80;Packet bad;need(!unpack(corrupt,bad),"corrupt packet accepted");
    }
    auto truncated=bytes;truncated.pop_back();Packet bad;need(!unpack(truncated,bad),"truncation accepted");
    auto oversized=bytes;set(oversized,12,Limit);set(oversized,oversized.size()-4,crc32(oversized,oversized.size()-4));need(!unpack(oversized,bad),"oversized length accepted");
    if(!p.starts.empty()) {auto invalid=bytes;set(invalid,28,p.n+1);set(invalid,invalid.size()-4,crc32(invalid,invalid.size()-4));need(!unpack(invalid,bad),"invalid chain index accepted");}
    return out;
}
static int selftest() {
    std::vector<Bytes> cases{{},{0},{255},{0,1},Bytes(4096,65)};
    Bytes alpha(4096);for(size_t i=0;i<alpha.size();i++)alpha[i]=static_cast<unsigned char>(i);cases.push_back(alpha);
    Bytes periodic(8193);for(size_t i=0;i<periodic.size();i++)periodic[i]="ABC"[i%3];cases.push_back(periodic);
    uint32_t state=0xc2021128u;
    for(size_t n:{3u,31u,257u,4099u,65537u,1048576u}) {Bytes b(n);for(auto& c:b){state^=state<<13;state^=state>>17;state^=state<<5;c=static_cast<unsigned char>(state);}cases.push_back(std::move(b));}
    unsigned checked=0;
    for(const auto& input:cases)for(unsigned k:Ks){auto p=own(input,k);verify(input,p);need(pack(p)==pack(own(input,k)),"nondeterministic representation");checked++;}
    std::cout<<"{\"event\":\"selftest_pass\",\"own_cases\":"<<checked<<",\"negative_controls\":true}\n";return 0;
}
static int prepare(const fs::path& inputdir,const fs::path& outputdir) {
    need(!fs::exists(outputdir),"prepare output must be fresh");fs::create_directories(outputdir);
    for(const char* name:{"d2_text_en","d2_text_src","d2_x86","d2_table_sdf","d2_table_db","d2_image","d2_xml"}) {
        auto input=read(inputdir/name);auto dir=outputdir/name;fs::create_directory(dir);
        write(dir/"original.bin",input);
        auto ref=reference(input);write(dir/"bsc.restored.bin",verify(input,ref));write(dir/"bsc.packet",pack(ref));
        for(unsigned k:Ks){auto p=own(input,k);auto stem="own-k"+std::to_string(k);write(dir/(stem+".restored.bin"),verify(input,p));need(pack(p)==pack(own(input,k)),"nondeterministic DEV-2 representation");write(dir/(stem+".packet"),pack(p));}
        std::cout<<"{\"event\":\"piece_prepared\",\"piece\":\""<<name<<"\",\"bytes\":"<<input.size()<<",\"roundtrip\":true,\"negative_controls\":true}\n"<<std::flush;
    }return 0;
}
static uint64_t ns(std::chrono::steady_clock::time_point a,std::chrono::steady_clock::time_point b) {return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(b-a).count());}
static int bench(const fs::path& packet,const fs::path& original,unsigned pf,uint64_t repeats) {
    need(pf<=1&&repeats>0&&repeats<=1024,"invalid bench arguments");
    char host[128]{};need(gethostname(host,sizeof(host)-1)==0&&std::string(host)=="ace-core","timing is restricted to ace-core");
    Packet p;need(unpack(read(packet),p),"invalid packet");auto input=read(original);need(input.size()==p.n,"original length");
    auto im=p.kind==0?image(p):crown2::Image{};auto ref=p.kind==1?reference_image(p):crown2::BaselineImage{};
    uint64_t total=0,build=0,walk=0;std::string error;
    Bytes warm=p.bwt;
    need(p.kind==0?crown2::decode(im,pf!=0,warm,error):crown2::baseline_decode_inplace(ref,warm,error),"warmup: "+error);
    need(warm==input,"warmup byte mismatch");
    for(uint64_t i=0;i<repeats;i++) {
        // Equal mutable-output setup outside both timers. bsc receives entropy
        // output in place in the actual codec; charging a retained-image copy
        // to its inverse phase would create an artificial penalty.
        Bytes out=p.bwt;crown2::Phases phases;
        auto start=std::chrono::steady_clock::now();
        bool ok=p.kind==0?crown2::decode(im,pf!=0,out,error,&phases):crown2::baseline_decode_inplace(ref,out,error);
        auto end=std::chrono::steady_clock::now();
        need(ok,"decode: "+error);need(out==input,"timed roundtrip byte mismatch");
        total+=ns(start,end);build+=phases.build_ns;walk+=phases.walk_ns;
    }
    std::cout<<"{\"event\":\"phase_cell\",\"kind\":"<<p.kind<<",\"k\":"<<p.k<<",\"prefetch\":"<<pf<<",\"bytes\":"<<p.n<<",\"representation_bytes\":"<<fs::file_size(packet)<<",\"repeats\":"<<repeats<<",\"untimed_warmups\":1,\"inverse_ns\":"<<total<<",\"table_ns\":"<<build<<",\"walk_ns\":"<<walk<<",\"roundtrip\":true}\n";return 0;
}
int main(int argc,char** argv) {
    try {
        if(argc==2&&std::string(argv[1])=="selftest")return selftest();
        if(argc==4&&std::string(argv[1])=="prepare")return prepare(argv[2],argv[3]);
        if(argc==7&&std::string(argv[1])=="bench"&&std::string(argv[6])=="ace-core")return bench(argv[2],argv[3],static_cast<unsigned>(std::stoul(argv[4])),std::stoull(argv[5]));
        // Sixth bench argument explicitly acknowledges timing host and keeps
        // accidental cloud timing out of the controller's supported invocation.
        std::cerr<<"usage: crown2_probe selftest | prepare INPUT_DIR FRESH_OUTPUT_DIR | bench PACKET ORIGINAL PREFETCH REPEATS ace-core\n";return 2;
    } catch(const std::exception& e){std::cerr<<"crown2: "<<e.what()<<'\n';return 1;}
}
