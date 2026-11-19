// SPDX-License-Identifier: MPL-2.0
#include "include/CEmberPDFTagReadAuxiliary.h"
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/Pipeline.hh>
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <map>
#include <set>
#include <string>
#include <libproc.h>
#include <mach/mach.h>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

namespace {
constexpr uint64_t maxInput = 128ULL * 1024 * 1024;
constexpr uint64_t maxOutput = 192ULL * 1024 * 1024;
constexpr uint32_t maxObjects = 250000;
constexpr size_t chunkBytes = 64 * 1024;
constexpr uint32_t maxGraphVisits = 16000000;
constexpr uint32_t maxContainerItems = 250000;
struct Failure { int32_t status; };
void check(bool condition, int32_t status) { if (!condition) throw Failure{status}; }
struct Cancellation {
    EmberTagReadAuxiliaryCancel callback; void *data;
    void poll() const { check(!callback || callback(data) == 0, EMBER_TAG_AUX_CANCELLED); }
};
bool sameVersion(struct stat const& a, struct stat const& b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
        && a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_gid == b.st_gid
        && a.st_nlink == b.st_nlink
        && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
        && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
        && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
        && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
}
std::array<uint8_t,32> digest(int fd, uint64_t count, Cancellation const& cancel) {
    CC_SHA256_CTX state; check(CC_SHA256_Init(&state) == 1, EMBER_TAG_AUX_INTERNAL);
    std::array<uint8_t,chunkBytes> buffer;
    uint64_t offset = 0;
    while (offset < count) {
        cancel.poll();
        size_t wanted = static_cast<size_t>(std::min<uint64_t>(count-offset,buffer.size()));
        ssize_t n = pread(fd,buffer.data(),wanted,static_cast<off_t>(offset));
        if (n < 0 && errno == EINTR) continue;
        check(n > 0 && static_cast<size_t>(n) <= wanted, EMBER_TAG_AUX_IO);
        check(CC_SHA256_Update(&state,buffer.data(),static_cast<CC_LONG>(n)) == 1, EMBER_TAG_AUX_INTERNAL);
        offset += static_cast<uint64_t>(n);
    }
    cancel.poll();
    std::array<uint8_t,32> value;
    check(CC_SHA256_Final(value.data(),&state) == 1, EMBER_TAG_AUX_INTERNAL);
    return value;
}
class Output final : public Pipeline {
    int fd; uint64_t limit; Cancellation cancel;
    std::array<unsigned char,chunkBytes> buffer{};
    size_t buffered = 0;
    uint64_t physicalOffset = 0;
    void flush() {
        cancel.poll();
        size_t offset = 0;
        while (offset < buffered) {
            cancel.poll();
            size_t wanted = buffered-offset;
            ssize_t n=pwrite(fd,buffer.data()+offset,wanted,static_cast<off_t>(physicalOffset));
            if (n<0 && errno==EINTR) continue;
            check(n>0 && static_cast<size_t>(n)<=wanted,EMBER_TAG_AUX_IO);
            physicalOffset+=static_cast<uint64_t>(n);offset+=static_cast<size_t>(n);
        }
        buffered=0;
    }
public:
    // Logical accepted bytes include the pending buffer. Caps therefore apply
    // before copying even when no physical write has been issued yet.
    uint64_t count = 0;
    Output(int f,uint64_t n,Cancellation c):Pipeline("ember-tag-read-auxiliary",nullptr),fd(f),limit(n),cancel(c) {}
    void write(unsigned char const* bytes,size_t length) override {
        cancel.poll();
        check(count<=limit && length<=limit-count,EMBER_TAG_AUX_LIMIT);
        while (length) {
            cancel.poll();size_t wanted=std::min(length,buffer.size()-buffered);
            std::memcpy(buffer.data()+buffered,bytes,wanted);
            buffered+=wanted;count+=static_cast<uint64_t>(wanted);bytes+=wanted;length-=wanted;
            if (buffered==buffer.size()) flush();
        }
    }
    // QPDF may call finish itself; the explicit caller finish is idempotent.
    void finish() override { cancel.poll();flush();cancel.poll(); }
};
struct FileCloser { void operator()(FILE *p) const { if (p) fclose(p); } };
struct TagProof {
    Cancellation cancel;
    std::map<QPDFObjGen,uint32_t> sourcePages, auxiliaryPages;
    std::map<QPDFObjGen,QPDFObjGen> forward, reverse;
    uint32_t visits=0;
    uint32_t pageCount=0;
    explicit TagProof(Cancellation c):cancel(c) {}
    void compare(QPDFObjectHandle a,QPDFObjectHandle b,uint32_t depth) {
        cancel.poll();check(depth<=64 && ++visits<=maxGraphVisits,EMBER_TAG_AUX_LIMIT);
        // Direct nulls have no page or indirect alias identity.
        // Keep cancellation, depth and visit accounting above unchanged.
        if (a.isNull() && b.isNull() && !a.isIndirect() && !b.isIndirect())
            return;
        auto sourcePage=sourcePages.find(a.getObjGen()), auxiliaryPage=auxiliaryPages.find(b.getObjGen());
        if (sourcePage!=sourcePages.end() || auxiliaryPage!=auxiliaryPages.end()) {
            check(sourcePage!=sourcePages.end() && auxiliaryPage!=auxiliaryPages.end()
                  && sourcePage->second==auxiliaryPage->second,EMBER_TAG_AUX_UNSUPPORTED);
            return; // Page dictionaries are symbols; never traverse painting/resources.
        }
        check(a.getTypeCode()==b.getTypeCode() && a.isIndirect()==b.isIndirect(),EMBER_TAG_AUX_UNSUPPORTED);
        if (a.isIndirect()) {
            auto source=a.getObjGen(), auxiliary=b.getObjGen();
            auto f=forward.find(source),r=reverse.find(auxiliary);
            if (f!=forward.end() || r!=reverse.end()) {
                check(f!=forward.end() && r!=reverse.end() && f->second==auxiliary && r->second==source,
                      EMBER_TAG_AUX_UNSUPPORTED);return;
            }
            forward.emplace(source,auxiliary);reverse.emplace(auxiliary,source);
        }
        if (a.isNull()) return;
        if (a.isBool()) {check(a.getBoolValue()==b.getBoolValue(),EMBER_TAG_AUX_UNSUPPORTED);return;}
        if (a.isInteger()) {check(a.unparseResolved()==b.unparseResolved(),EMBER_TAG_AUX_UNSUPPORTED);return;}
        if (a.isReal()) {check(a.getRealValue()==b.getRealValue(),EMBER_TAG_AUX_UNSUPPORTED);return;}
        if (a.isName() || a.isString()) {
            auto x=a.isName()?a.getName():a.getStringValue(), y=b.isName()?b.getName():b.getStringValue();
            check(x.size()<=1024*1024 && y.size()<=1024*1024,EMBER_TAG_AUX_LIMIT);
            check(x==y,EMBER_TAG_AUX_UNSUPPORTED);return;
        }
        if (a.isArray()) {
            auto n=a.getArrayNItems();check(n==b.getArrayNItems(),EMBER_TAG_AUX_UNSUPPORTED);
            check(visits<=maxGraphVisits && n>=0 && static_cast<uint64_t>(n)<=maxContainerItems
                  && static_cast<uint64_t>(n)<=maxGraphVisits-visits,EMBER_TAG_AUX_LIMIT);
            for(int i=0;i<n;++i) compare(a.getArrayItem(i),b.getArrayItem(i),depth+1);
            return;
        }
        check(a.isDictionary() && !a.isStream(),EMBER_TAG_AUX_UNSUPPORTED);
        // getKeys()/hasKey() intentionally hide explicit null members.
        // Raw preservation proof must include those original dictionary slots.
        auto entries=a.getDictAsMap(), other=b.getDictAsMap();
        check(entries.size()==other.size(),EMBER_TAG_AUX_UNSUPPORTED);
        check(visits<=maxGraphVisits && entries.size()<=4096
              && entries.size()<=maxGraphVisits-visits,EMBER_TAG_AUX_LIMIT);
        // A tag donor may describe only ordinary structure and inert/current
        // Link references. Nested painting or appearance graphs are ineligible.
        check(!entries.count("/Stm") && !entries.count("/AP") && !entries.count("/AA") && !entries.count("/FT"),
              EMBER_TAG_AUX_UNSUPPORTED);
        if(entries.count("/Subtype"))
            check(a.getKey("/Subtype").isNameAndEquals("/Link"),EMBER_TAG_AUX_UNSUPPORTED);
        check(!a.getKey("/Type").isNameAndEquals("/XObject"),EMBER_TAG_AUX_UNSUPPORTED);
        auto otherEntry=other.begin();
        for(auto const& entry:entries) {
            check(entry.first.size()<=64*1024,EMBER_TAG_AUX_LIMIT);
            check(otherEntry!=other.end() && entry.first==otherEntry->first,EMBER_TAG_AUX_UNSUPPORTED);
            compare(entry.second,otherEntry->second,depth+1);++otherEntry;
        }
    }
    void run(QPDF& source,QPDF& auxiliary) {
        cancel.poll();auto const& a=source.getAllPages();auto const& b=auxiliary.getAllPages();
        check(a.size()==b.size() && !a.empty() && a.size()<=250000,EMBER_TAG_AUX_UNSUPPORTED);
        pageCount=static_cast<uint32_t>(a.size());
        for(uint32_t i=0;i<pageCount;++i) {
            cancel.poll();check(a[i].isIndirect() && b[i].isIndirect(),EMBER_TAG_AUX_UNSUPPORTED);
            check(sourcePages.emplace(a[i].getObjGen(),i).second && auxiliaryPages.emplace(b[i].getObjGen(),i).second,
                  EMBER_TAG_AUX_UNSUPPORTED);
        }
        auto original=source.getRoot().getKey("/StructTreeRoot"), copy=auxiliary.getRoot().getKey("/StructTreeRoot");
        check(original.isDictionary() && original.getKey("/Type").isNameAndEquals("/StructTreeRoot"),
              EMBER_TAG_AUX_UNSUPPORTED);
        compare(original,copy,0);cancel.poll();
        check(!source.anyWarnings() && !auxiliary.anyWarnings(),EMBER_TAG_AUX_PARSE_OR_WARNING);
    }
};
}
extern "C" int32_t ember_tag_read_auxiliary(
    int32_t input_fd,int32_t output_fd,const uint8_t expected_input_sha256[32],
    EmberTagReadAuxiliaryLimits limits,EmberTagReadAuxiliaryCancel callback,void *user_data,
    EmberTagReadAuxiliaryReceipt *out_receipt) {
    if (out_receipt) std::memset(out_receipt,0,sizeof(*out_receipt));
    bool ownedOutput = false;
    try {
        check(out_receipt && expected_input_sha256 && input_fd>=0 && output_fd>=0 && input_fd!=output_fd,
              EMBER_TAG_AUX_ARGUMENT);
        check(limits.max_input_bytes>0 && limits.max_input_bytes<=maxInput
              && limits.max_output_bytes>0 && limits.max_output_bytes<=maxOutput
              && limits.max_objects>0 && limits.max_objects<=maxObjects,EMBER_TAG_AUX_ARGUMENT);
        Cancellation cancel{callback,user_data}; cancel.poll();
        struct stat original{}, output{};
        check(fstat(input_fd,&original)==0 && fstat(output_fd,&output)==0,EMBER_TAG_AUX_IO);
        int inputFlags=fcntl(input_fd,F_GETFL), outputFlags=fcntl(output_fd,F_GETFL);
        check(inputFlags>=0 && outputFlags>=0 && (inputFlags&O_ACCMODE)==O_RDONLY
              && (outputFlags&O_ACCMODE)==O_RDWR,EMBER_TAG_AUX_ARGUMENT);
        check(S_ISREG(original.st_mode) && original.st_size>0,EMBER_TAG_AUX_ARGUMENT);
        check(S_ISREG(output.st_mode) && output.st_uid==geteuid() && (output.st_mode&07777)==0600
              && output.st_nlink==1 && output.st_size==0
              && !(original.st_dev==output.st_dev && original.st_ino==output.st_ino),EMBER_TAG_AUX_ARGUMENT);
        ownedOutput=true;
        check(static_cast<uint64_t>(original.st_size)<=limits.max_input_bytes,EMBER_TAG_AUX_LIMIT);
        auto beforeHash=digest(input_fd,static_cast<uint64_t>(original.st_size),cancel);
        check(std::memcmp(beforeHash.data(),expected_input_sha256,32)==0,EMBER_TAG_AUX_INPUT_CHANGED);
        struct stat afterHash{};check(fstat(input_fd,&afterHash)==0,EMBER_TAG_AUX_IO);
        check(sameVersion(original,afterHash),EMBER_TAG_AUX_INPUT_CHANGED);
        int duplicate=dup(input_fd);check(duplicate>=0,EMBER_TAG_AUX_IO);
        FILE *raw=fdopen(duplicate,"rb");if (!raw) {close(duplicate);throw Failure{EMBER_TAG_AUX_IO};}
        std::unique_ptr<FILE,FileCloser> file(raw);
        QPDF pdf; pdf.setSuppressWarnings(true); pdf.setAttemptRecovery(false);
        cancel.poll();pdf.processFile("inherited-tag-input",file.get(),false);cancel.poll();
        check(!pdf.anyWarnings(),EMBER_TAG_AUX_PARSE_OR_WARNING);
        check(!pdf.isEncrypted(),EMBER_TAG_AUX_UNSUPPORTED);
        // The xref includes compressed members. Enforce object cardinality
        // before writer traversal can materialize all indirect objects.
        auto xref=pdf.getXRefTable();cancel.poll();
        check(xref.size()<=limits.max_objects,EMBER_TAG_AUX_LIMIT);
        uint32_t objects=static_cast<uint32_t>(xref.size());xref.clear();
        check(!pdf.anyWarnings(),EMBER_TAG_AUX_PARSE_OR_WARNING);
        Output pipeline(output_fd,limits.max_output_bytes,cancel);
        QPDFWriter writer(pdf);writer.setOutputPipeline(&pipeline);
        writer.setObjectStreamMode(qpdf_o_disable);
        writer.setStreamDataMode(qpdf_s_preserve);
        writer.setContentNormalization(false);
        writer.setPreserveUnreferencedObjects(true);
        cancel.poll();writer.write();pipeline.finish();cancel.poll();
        check(!pdf.anyWarnings(),EMBER_TAG_AUX_PARSE_OR_WARNING);
        struct stat after{}, written{};
        check(fstat(input_fd,&after)==0 && fstat(output_fd,&written)==0,EMBER_TAG_AUX_IO);
        check(sameVersion(original,after),EMBER_TAG_AUX_INPUT_CHANGED);
        check(S_ISREG(written.st_mode) && written.st_uid==output.st_uid && written.st_mode==output.st_mode
              && written.st_dev==output.st_dev && written.st_ino==output.st_ino && written.st_nlink==1
              && written.st_size>0 && static_cast<uint64_t>(written.st_size)==pipeline.count,
              EMBER_TAG_AUX_INPUT_CHANGED);
        auto afterInputHash=digest(input_fd,static_cast<uint64_t>(original.st_size),cancel);
        check(beforeHash==afterInputHash,EMBER_TAG_AUX_INPUT_CHANGED);
        auto outputHash=digest(output_fd,pipeline.count,cancel);
        int auxiliaryDuplicate=dup(output_fd);check(auxiliaryDuplicate>=0,EMBER_TAG_AUX_IO);
        FILE *auxiliaryRaw=fdopen(auxiliaryDuplicate,"rb");
        if(!auxiliaryRaw) {close(auxiliaryDuplicate);throw Failure{EMBER_TAG_AUX_IO};}
        std::unique_ptr<FILE,FileCloser> auxiliaryFile(auxiliaryRaw);
        QPDF auxiliary;auxiliary.setSuppressWarnings(true);auxiliary.setAttemptRecovery(false);
        cancel.poll();auxiliary.processFile("inherited-tag-auxiliary",auxiliaryFile.get(),false);cancel.poll();
        check(!auxiliary.anyWarnings() && !auxiliary.isEncrypted(),EMBER_TAG_AUX_PARSE_OR_WARNING);
        check(auxiliary.getXRefTable().size()<=limits.max_objects,EMBER_TAG_AUX_LIMIT);
        TagProof proof(cancel);proof.run(pdf,auxiliary);
        struct stat finalOutput{};check(fstat(output_fd,&finalOutput)==0 && sameVersion(written,finalOutput),
                                       EMBER_TAG_AUX_INPUT_CHANGED);
        check(digest(output_fd,pipeline.count,cancel)==outputHash,EMBER_TAG_AUX_INPUT_CHANGED);
        check(fstat(input_fd,&after)==0 && sameVersion(original,after),EMBER_TAG_AUX_INPUT_CHANGED);
        cancel.poll();
        out_receipt->input_bytes=static_cast<uint64_t>(original.st_size);
        out_receipt->output_bytes=pipeline.count;out_receipt->object_count=objects;
        out_receipt->page_count=proof.pageCount;out_receipt->tag_nodes=proof.visits;
        out_receipt->raw_tag_graph_equivalent=1;
        std::copy(beforeHash.begin(),beforeHash.end(),out_receipt->input_sha256);
        std::copy(outputHash.begin(),outputHash.end(),out_receipt->output_sha256);
        return EMBER_TAG_AUX_OK;
    } catch (Failure const& f) {
        if (ownedOutput) (void)ftruncate(output_fd,0);
        return f.status;
    } catch (std::exception const&) {
        if (ownedOutput) (void)ftruncate(output_fd,0);
        return EMBER_TAG_AUX_PARSE_OR_WARNING;
    } catch (...) {
        if (ownedOutput) (void)ftruncate(output_fd,0);
        return EMBER_TAG_AUX_INTERNAL;
    }
}

extern "C" int32_t ember_pdf_read_worker_process_info(int32_t pid,uint64_t *start_sec,
    uint64_t *start_usec,int32_t *parent_pid,uint64_t *resident_bytes) {
    if(start_sec) *start_sec=0;if(start_usec) *start_usec=0;
    if(parent_pid) *parent_pid=0;if(resident_bytes) *resident_bytes=0;
    if(pid<=0 || !start_sec || !start_usec || !parent_pid || !resident_bytes) return 0;
    struct proc_bsdinfo first{},last{};struct proc_taskinfo task{};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&first,sizeof(first))!=sizeof(first)
       || proc_pidinfo(pid,PROC_PIDTASKINFO,0,&task,sizeof(task))!=sizeof(task)
       || proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&last,sizeof(last))!=sizeof(last)
       || first.pbi_pid!=static_cast<uint32_t>(pid) || first.pbi_pid!=last.pbi_pid
       || first.pbi_ppid!=last.pbi_ppid || first.pbi_start_tvsec!=last.pbi_start_tvsec
       || first.pbi_start_tvusec!=last.pbi_start_tvusec || task.pti_resident_size==0) return 0;
    *start_sec=first.pbi_start_tvsec;*start_usec=first.pbi_start_tvusec;
    *parent_pid=static_cast<int32_t>(first.pbi_ppid);*resident_bytes=task.pti_resident_size;return 1;
}

extern "C" int32_t ember_pdf_current_worker_resident_bytes(uint64_t *resident_bytes) {
    if(resident_bytes) *resident_bytes=0;
    if(!resident_bytes) return 0;
    mach_task_basic_info_data_t info{};mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    if(task_info(mach_task_self(),MACH_TASK_BASIC_INFO,reinterpret_cast<task_info_t>(&info),&count)!=KERN_SUCCESS
       || count!=MACH_TASK_BASIC_INFO_COUNT || info.resident_size==0) return 0;
    *resident_bytes=info.resident_size;return 1;
}
