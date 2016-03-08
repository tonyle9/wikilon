
#include <string.h>
#include <assert.h>
#include <stdio.h>

#include "wikrt.h"


void wikrt_acquire_shared_memory(wikrt_cx* cx, wikrt_sizeb sz); 

static inline bool wikrt_alloc_local(wikrt_cx* cx, wikrt_sizeb sz, wikrt_addr* addr) 
{
    if(wikrt_fl_alloc(cx->memory, &(cx->fl), sz, addr)) {
        cx->ct_bytes_alloc += sz;
        return true;
    }
    return false;
}

bool wikrt_alloc(wikrt_cx* cx, wikrt_size sz, wikrt_addr* addr) 
{
    sz = WIKRT_CELLBUFF(sz);
    if(wikrt_alloc_local(cx, sz, addr)) {
        // should succeed most times
        return true; 
    }
    // otherwise acquire a bunch of memory, then retry.
    wikrt_acquire_shared_memory(cx, WIKRT_PAGEBUFF(sz));
    return wikrt_alloc_local(cx, sz, addr);
}

static inline bool wikrt_acquire_shm(wikrt_cx* cx, wikrt_sizeb sz) 
{
    // assuming cxm lock is held
    wikrt_addr block;
    if(wikrt_fl_alloc(cx->memory, &(cx->cxm->fl), sz, &block)) {
        wikrt_fl_free(cx->memory, &(cx->fl), sz, block);
        return true;
    }
    return false;
}

void wikrt_acquire_shared_memory(wikrt_cx* cx, wikrt_sizeb sz)
{
    // I want a simple, predictable heuristic strategy that is very
    // fast for smaller computations (the majority of Wikilon ops).
    //
    // Current approach:
    // 
    // - allocate space directly, if feasible.
    // - otherwise: merge, coalesce, retry once.
    // - fallback: acquire all shared space.
    //
    // This should be combined with mechanisms to release memory if
    // a thread is holding onto too much, i.e. such that threads can
    // gradually shift ownership of blocks of code.
    wikrt_cxm* const cxm = cx->cxm;
    void* const mem = cx->memory;
    wikrt_cxm_lock(cxm); {
        if(!wikrt_acquire_shm(cx, sz)) {
            wikrt_fl_merge(mem, &(cx->fl), &(cxm->fl));
            wikrt_fl_coalesce(mem, &(cxm->fl));
            cx->fl = (wikrt_fl) { 0 };
            if(!wikrt_acquire_shm(cx, sz)) {
                wikrt_fl_merge(mem, &(cxm->fl), &(cx->fl));
                cxm->fl = (wikrt_fl) { 0 };
            }
        }
    } wikrt_cxm_unlock(cxm);

    // TODO: latent deletion, could be useful.
    // TODO: latent stowage? or elsewhere?
}

void wikrt_free(wikrt_cx* cx, wikrt_size sz, wikrt_addr addr) 
{
    sz = WIKRT_CELLBUFF(sz);
    wikrt_fl_free(cx->memory, &(cx->fl), sz, addr);
    cx->ct_bytes_freed += sz;

    // TODO
    // If a thread has a lot of free space, we may need to release 
    // some of it back to the common pool. It might be better to 
    // do this at an external 'boundary' such as the wikrt_eval API.
    // For the moment, this is non-critical.
}


bool wikrt_realloc(wikrt_cx* cx, wikrt_size sz0, wikrt_addr* addr, wikrt_size szf)
{
    sz0 = WIKRT_CELLBUFF(sz0);
    szf = WIKRT_CELLBUFF(szf);
    if(sz0 == szf) {
        // no buffered size change 
        return true; 
    } else if(szf < sz0) { 
        // free up a little space at the end of the buffer
        wikrt_free(cx, (sz0 - szf), ((*addr) + szf)); 
        return true; 
    } else {
        // As an optimization, in-place growth is unreliable and
        // unpredictable. So, Wikilon runtime doesn't bother. We'll
        // simply allocate, shallow-copy, and free the original.
        wikrt_addr const src = (*addr);
        wikrt_addr dst;
        if(!wikrt_alloc(cx, szf, &dst)) {
            return false;
        }
        void* const pdst = (void*) wikrt_pval(cx, dst);
        void const* const psrc = (void*) wikrt_pval(cx, src);
        memcpy(pdst, psrc, sz0);
        wikrt_free(cx, sz0, src);
        (*addr) = dst;
        return true;
    }
}

wikrt_err _wikrt_peek_type(wikrt_cx* cx, wikrt_vtype* out, wikrt_val const v)
{
    if(wikrt_i(v)) { 
        (*out) = WIKRT_VTYPE_INTEGER; 
    } else {
        wikrt_tag const vtag = wikrt_vtag(v);
        wikrt_addr const vaddr = wikrt_vaddr(v);
        if(WIKRT_P == vtag) {
            if(0 == vaddr) { (*out) = WIKRT_VTYPE_UNIT; }
            else { (*out) = WIKRT_VTYPE_PRODUCT; }
        } else if((WIKRT_PL == vtag) || (WIKRT_PR == vtag)) {
            (*out) = WIKRT_VTYPE_SUM;
        } else if((WIKRT_O == vtag) && (0 != vaddr)) {
            wikrt_val* const pv = wikrt_pval(cx, vaddr);
            wikrt_val const otag = pv[0];
            switch(LOBYTE(otag)) {
                case WIKRT_OTAG_BIGINT: {
                    (*out) = WIKRT_VTYPE_INTEGER;
                } break;
                case WIKRT_OTAG_ARRAY: // same as sum
                case WIKRT_OTAG_BINARY: // same as sum
                case WIKRT_OTAG_TEXT: // same as sum
                case WIKRT_OTAG_DEEPSUM: {
                    (*out) = WIKRT_VTYPE_SUM;
                } break;
                case WIKRT_OTAG_BLOCK: {
                    (*out) = WIKRT_VTYPE_BLOCK;
                } break;
                case WIKRT_OTAG_SEAL_SM: // same as SEAL
                case WIKRT_OTAG_SEAL: {
                    (*out) = WIKRT_VTYPE_SEALED;
                } break;
                case WIKRT_OTAG_STOWAGE: {
                    // TODO: consider capturing vtype in stowage tags!
                    (*out) = WIKRT_VTYPE_STOWED;
                } break;
                default: {
                    fprintf(stderr, u8"wikrt: peek type: unrecognized tag %u\n"
                                  , (unsigned int)pv[0]);
                    return WIKRT_INVAL;
                } break;
            }
        } else { 
            (*out) = WIKRT_VTYPE_PENDING; 
            return WIKRT_INVAL; 
        }
    }
    return WIKRT_OK;
}

/* Currently allocating as a normal list. This means we allocate one
 * full cell (WIKRT_CELLSIZE) per character, usually an 8x increase.
 * Yikes! But I plan to later tune this to a dedicated structure.
 */
wikrt_err _wikrt_alloc_text(wikrt_cx* cx, wikrt_val* txt, char const* cstr, size_t len) 
{ 
    _Static_assert((sizeof(char) == sizeof(uint8_t)), "invalid cast from char* to utf8_t*");
    uint8_t const* s = (uint8_t const*) cstr;

    (*txt) = WIKRT_VOID;
    wikrt_val* tl = txt;
    uint32_t cp;
    while((len != 0) && utf8_step(&s, &len, &cp)) {
        if(!wikrt_text_char(cp)) { return WIKRT_INVAL; }
        if(!wikrt_alloc_cellval(cx, tl, WIKRT_PL, wikrt_i2v((int32_t)cp), WIKRT_VOID)) { return WIKRT_CXFULL; }
        tl = 1 + wikrt_pval(cx, wikrt_vaddr(*tl));
    }

    (*tl) = WIKRT_UNIT_INR;
    return WIKRT_OK;
}



/* For the moment, we'll allocate a binary as a plain old list.
 * This results in an WIKRT_CELLSIZE (8x) expansion at this time. I
 * I will support more compact representations later.
 */
wikrt_err _wikrt_alloc_binary(wikrt_cx* cx, wikrt_val* v, uint8_t const* buff, size_t nBytes) 
{
    (*v) = WIKRT_VOID;
    wikrt_val* tl = v;
    uint8_t const* const buffEnd = buff + nBytes;
    while(buff != buffEnd) {
        uint8_t const e = *(buff++);
        if(!wikrt_alloc_cellval(cx, tl, WIKRT_PL, wikrt_i2v((int32_t)e), WIKRT_VOID)) { return WIKRT_CXFULL; }
        tl = 1 + wikrt_pval(cx, wikrt_vaddr(*tl));
    }
    (*tl) = WIKRT_UNIT_INR;
    return WIKRT_OK;
}

wikrt_err wikrt_alloc_medint(wikrt_cx* cx, wikrt_val* v, bool positive, uint32_t d0, uint32_t d1, uint32_t d2)
{
    if(0 == d2) {
        wikrt_size const nDigits = 2;
        wikrt_size const allocSz = sizeof(wikrt_val) + (nDigits * sizeof(uint32_t));
        wikrt_addr addr;
        if(!wikrt_alloc(cx, allocSz, &addr)) { return WIKRT_CXFULL; }
        (*v) = wikrt_tag_addr(WIKRT_O, addr);
        wikrt_val* const p = wikrt_pval(cx, addr);
        p[0] = wikrt_mkotag_bigint(positive, nDigits);
        uint32_t* const d = (uint32_t*)(p + 1);
        d[0] = d0;
        d[1] = d1;
        return WIKRT_OK;
    } else {
        wikrt_size const nDigits = 3;
        wikrt_size const allocSz = sizeof(wikrt_val) + (nDigits * sizeof(uint32_t));
        wikrt_addr addr;
        if(!wikrt_alloc(cx, allocSz, &addr)) { return WIKRT_CXFULL; }
        (*v) = wikrt_tag_addr(WIKRT_O, addr);
        wikrt_val* const p = wikrt_pval(cx, addr);
        p[0] = wikrt_mkotag_bigint(positive, nDigits);
        uint32_t* const d = (uint32_t*)(p + 1);
        d[0] = d0;
        d[1] = d1;
        d[2] = d2;
        return WIKRT_OK;
    }
}

wikrt_err wikrt_peek_medint(wikrt_cx* cx, wikrt_val v, bool* positive, uint32_t* d0, uint32_t* d1, uint32_t* d2)
{
    if(wikrt_i(v)) {
        int32_t n = wikrt_v2i(v);
        (*positive) = (n >= 0);
        n = (*positive) ? n : -n;
        (*d0) = n % WIKRT_BIGINT_DIGIT;
        (*d1) = n / WIKRT_BIGINT_DIGIT;
        (*d2) = 0;
        return WIKRT_OK;
    }

    wikrt_tag const tag = wikrt_vtag(v);
    wikrt_addr const addr = wikrt_vaddr(v);
    wikrt_val const* const pv = wikrt_pval(cx, addr);
    bool const isBigInt = (0 != addr) && (WIKRT_O == tag) && (wikrt_otag_bigint(*pv));
    if(!isBigInt) { 
        (*positive) = false; 
        (*d0) = 0; (*d1) = 0; (*d2) = 0;
        return WIKRT_TYPE_ERROR; 
    }

    wikrt_size const nDigits = (*pv) >> 9;
    uint32_t const* const d = (uint32_t*)(pv + 1);
    (*positive) = (0 == ((1 << 8) & (*pv)));
    (*d0) = d[0];
    (*d1) = d[1];
    (*d2) = (nDigits > 2) ? d[2] : 0;
    return (nDigits > 3) ? WIKRT_BUFFSZ : WIKRT_OK;
}


wikrt_err _wikrt_alloc_i32(wikrt_cx* cx, wikrt_val* v, int32_t n) 
{
    if((WIKRT_SMALLINT_MIN <= n) && (n <= WIKRT_SMALLINT_MAX)) {
        (*v) = wikrt_i2v(n);
        return WIKRT_OK;
    }

    bool positive;
    uint32_t d0, d1;
    if(n != INT32_MIN) {
        _Static_assert(((INT32_MAX + INT32_MIN) == (-1)), "bad assumption (int32_t)");
        positive = (n >= 0);
        n = positive ? n : -n;
        d0 = n % WIKRT_BIGINT_DIGIT;
        d1 = n / WIKRT_BIGINT_DIGIT;
    } else {
        _Static_assert((-2147483648 == INT32_MIN), "bad INT32_MIN");
        positive = false;
        d1 = 2;
        d0 = 147483648;
    }
    return wikrt_alloc_medint(cx, v, positive, d0, d1, 0);
}


wikrt_err _wikrt_alloc_i64(wikrt_cx* cx, wikrt_val* v, int64_t n) 
{
    if((WIKRT_SMALLINT_MIN <= n) && (n <= WIKRT_SMALLINT_MAX)) {
        (*v) = wikrt_i2v((int32_t)n);
        return WIKRT_OK;
    }

    bool positive;
    uint32_t d0, d1, d2;
    if(n != INT64_MIN) {
        _Static_assert(((INT64_MAX + INT64_MIN) == (-1)), "bad assumption (int64_t)");
        positive = (n >= 0);
        n = positive ? n : -n;
        d0 = n % WIKRT_BIGINT_DIGIT;
        n /= WIKRT_BIGINT_DIGIT;
        d1 = n % WIKRT_BIGINT_DIGIT;
        d2 = n / WIKRT_BIGINT_DIGIT;
    } else {
        // GCC complains with the INT64_MIN constant given directly.
        _Static_assert(((-9223372036854775807 - 1) == INT64_MIN), "bad INT64_MIN");
        positive = false;
        d2 = 9;
        d1 = 223372036;
        d0 = 854775808;
    }
    return wikrt_alloc_medint(cx, v, positive, d0, d1, d2);
}


wikrt_err _wikrt_peek_i32(wikrt_cx* cx, wikrt_val const v, int32_t* i32) 
{
    // small integers (normal case)
    if(wikrt_i(v)) {
        (*i32) = wikrt_v2i(v);
        return WIKRT_OK;
    } 

    bool positive;
    uint32_t d0, d1, d2;
    wikrt_err const st = wikrt_peek_medint(cx, v, &positive, &d0, &d1, &d2);
    if(WIKRT_OK != st) { 
        (*i32) = positive ? INT32_MAX : INT32_MIN;
        return st;
    }
    int32_t const digit = WIKRT_BIGINT_DIGIT;

    if(positive) {
        _Static_assert((2147483647 == INT32_MAX), "bad INT32_MAX");
        uint32_t const d1m = 2;
        uint32_t const d0m = 147483647;
        bool const overflow = (d2 != 0) || (d1 > d1m) || ((d1 == d1m) && (d0 > d0m));
        if(overflow) { (*i32) = INT32_MAX; return WIKRT_BUFFSZ; }
        (*i32) = (d1 * digit) + d0;
        return WIKRT_OK;
    } else {
        _Static_assert((-2147483648 == INT32_MIN), "bad INT32_MIN");
        uint32_t const d1m = 2;
        uint32_t const d0m = 147483648;
        bool const underflow = (d2 != 0) || (d1 > d1m) || ((d1 == d1m) && (d0 > d0m));
        if(underflow) { (*i32) = INT32_MIN; return WIKRT_BUFFSZ; }
        (*i32) = 0 - ((int32_t)d1 * digit) - (int32_t)d0;
        return WIKRT_OK;
    }
}

wikrt_err _wikrt_peek_i64(wikrt_cx* cx, wikrt_val const v, int64_t* i64) 
{
    if(wikrt_i(v)) {
        (*i64) = (int64_t) wikrt_v2i(v);
        return WIKRT_OK;
    }

    bool positive;
    uint32_t d0, d1, d2;
    wikrt_err const st = wikrt_peek_medint(cx, v, &positive, &d0, &d1, &d2);
    if(WIKRT_OK != st) { 
        (*i64) = positive ? INT64_MAX : INT64_MIN;
        return st;
    }
    int64_t const digit = WIKRT_BIGINT_DIGIT;

    if(0 == d2) {
        // nDigits is exactly 2 by construction, no risk of over or underflow
        int64_t const iAbs = ((int64_t)d1 * digit) + d0;
        (*i64) = positive ? iAbs : -iAbs;
        return WIKRT_OK;
    } else if(positive) {
        _Static_assert((9223372036854775807 == INT64_MAX), "bad INT64_MAX");
        uint32_t const d2m = 9;
        uint32_t const d1m = 223372036;
        uint32_t const d0m = 854775807;
        bool const overflow = (d2 > d2m) ||
            ((d2 == d2m) && ((d1 > d1m) || ((d1 == d1m) && (d0 > d0m))));
        if(overflow) { (*i64) = INT64_MAX; return WIKRT_BUFFSZ; }
        (*i64) = ((int64_t)d2 * (digit * digit)) 
               + ((int64_t)d1 * (digit))
               + ((int64_t)d0);
        return WIKRT_OK;
    } else {
        // GCC complains with the INT64_MIN constant given directly.
        _Static_assert(((-9223372036854775807 - 1) == INT64_MIN), "bad INT64_MIN");
        uint32_t const d2m = 9;
        uint32_t const d1m = 223372036;
        uint32_t const d0m = 854775808;
        bool const underflow = (d2 > d2m) ||
            ((d2 == d2m) && ((d1 > d1m) || ((d1 == d1m) && (d0 > d0m))));
        if(underflow) { (*i64) = INT64_MIN; return WIKRT_BUFFSZ; }
        (*i64) = 0 - ((int64_t)d2 * (digit * digit))
                   - ((int64_t)d1 * (digit))
                   - ((int64_t)d0);
        return WIKRT_OK;
    }
}

static inline size_t wikrt_decimal_size(uint32_t n) {
    size_t ct = 0;
    do { ++ct; n /= 10; } while(n > 0);
    return ct;
}


wikrt_err _wikrt_peek_istr(wikrt_cx* cx, wikrt_val const v, char* const buff, size_t* const buffsz)
{
    bool positive;
    uint32_t upperDigit;
    uint32_t innerDigitCt;
    uint32_t const* d;

    size_t const buffsz_avail = (*buffsz);

    if(wikrt_i(v)) {
        _Static_assert((WIKRT_SMALLINT_MIN == (- WIKRT_SMALLINT_MAX)), "negation of smallint must be closed");
        int32_t const i = wikrt_v2i(v);

        positive = (i >= 0);
        upperDigit = (uint32_t)(positive ? i : -i);
        innerDigitCt = 0;
        d = NULL;
    } else {
        wikrt_tag const tag = wikrt_vtag(v);
        wikrt_addr const addr = wikrt_vaddr(v);
        wikrt_val const* const pv = wikrt_pval(cx, addr);
        bool const isBigInt = (WIKRT_O == tag) && (0 != addr) && (wikrt_otag_bigint(*pv));
        if(!isBigInt) { return WIKRT_TYPE_ERROR; }
        
        d = (uint32_t*)(pv + 1);
        positive = (0 == ((1 << 8) & (*pv)));
        innerDigitCt = ((*pv) >> 9) - 1;
        upperDigit = d[innerDigitCt];
    }



    size_t const buffsz_min = (positive ? 0 : 1) // sign
                            + wikrt_decimal_size(upperDigit)
                            + (9 * innerDigitCt);

    (*buffsz) = buffsz_min;
    if(buffsz_min > buffsz_avail) { return WIKRT_BUFFSZ; }

    char* s = buff + buffsz_min;
    #define WD(n) { *(--s) = ('0' + (n % 10)); n /= 10; }
    for(uint32_t ii = 0; ii < innerDigitCt; ++ii) {
        // nine decimal digits per inner digit
        uint32_t n = d[ii];
        WD(n); WD(n); WD(n);
        WD(n); WD(n); WD(n);
        WD(n); WD(n); WD(n);
    }
    do { WD(upperDigit); } while(0 != upperDigit);
    if(!positive) { *(--s) = '-'; }
    assert(buff == s); // assert match expected size
    #undef WD

    return WIKRT_OK;
}

wikrt_err _wikrt_alloc_istr(wikrt_cx* cx, wikrt_val* v, char const* istr, size_t strlen)
{
    (*v) = WIKRT_VOID;
    return WIKRT_IMPL;
}

wikrt_err _wikrt_alloc_prod(wikrt_cx* cx, wikrt_val* p, wikrt_val fst, wikrt_val snd) 
{
    if(!wikrt_alloc_cellval(cx, p, WIKRT_P, fst, snd)) {
        (*p) = WIKRT_VOID;
        return WIKRT_CXFULL;
    } 
    return WIKRT_OK;
}


wikrt_err _wikrt_split_prod(wikrt_cx* cx, wikrt_val p, wikrt_val* fst, wikrt_val* snd) 
{
    wikrt_tag const ptag = wikrt_vtag(p);
    wikrt_addr const paddr = wikrt_vaddr(p);
    if((WIKRT_P == ptag) && (0 != paddr)) {
        wikrt_val* const pv = wikrt_pval(cx, paddr);
        (*fst) = pv[0];
        (*snd) = pv[1];
        wikrt_free(cx, WIKRT_CELLSIZE, paddr);
        return WIKRT_OK;
    } else {
        (*fst) = WIKRT_VOID;
        (*snd) = WIKRT_VOID;
        return WIKRT_TYPE_ERROR;
    }
}
 
wikrt_err _wikrt_alloc_sum(wikrt_cx* cx, wikrt_val* c, bool inRight, wikrt_val v) 
{
    wikrt_tag const vtag = wikrt_vtag(v);
    wikrt_addr const vaddr = wikrt_vaddr(v);
    wikrt_val* const pv = wikrt_pval(cx, vaddr);
    if(WIKRT_P == vtag) {
        // shallow sum on product, pointer manipulation, no allocation
        wikrt_tag const newtag = inRight ? WIKRT_PR : WIKRT_PL;
        (*c) = wikrt_tag_addr(newtag, vaddr);
        return WIKRT_OK;
    } else if((WIKRT_O == vtag) && wikrt_otag_deepsum(*pv) && ((*pv) < (1 << 30))) {
        // deepsum has space if bits 30 and 31 are available, i.e. if tag less than (1 << 30).
        // In this case, no allocation is required. We can update the existing deep sum in place.
        wikrt_val const s0 = (*pv) >> 8;
        wikrt_val const sf = (s0 << 2) | (inRight ? WIKRT_DEEPSUMR : WIKRT_DEEPSUML);
        wikrt_val const otag = (sf << 8) | WIKRT_OTAG_DEEPSUM;
        (*pv) = otag;
        (*c) = v;
        return WIKRT_OK;
    } else { // need to allocate space
        wikrt_val const sf = (inRight ? WIKRT_DEEPSUMR : WIKRT_DEEPSUML);
        wikrt_val const otag = (sf << 8) | WIKRT_OTAG_DEEPSUM;
        if(!wikrt_alloc_cellval(cx, c, WIKRT_O, otag, v)) {  return WIKRT_CXFULL; }
        return WIKRT_OK;
    }
}


wikrt_err _wikrt_split_sum(wikrt_cx* cx, wikrt_val c, bool* inRight, wikrt_val* v) 
{
    wikrt_tag const tag = wikrt_vtag(c);
    wikrt_addr const addr = wikrt_vaddr(c);
    if(WIKRT_PL == tag) {
        (*inRight) = false;
        (*v) = wikrt_tag_addr(WIKRT_P, addr);
        return WIKRT_OK;
    } else if(WIKRT_PR == tag) {
        (*inRight) = true;
        (*v) = wikrt_tag_addr(WIKRT_P, addr);
        return WIKRT_OK;
    } else if(WIKRT_O == tag) {
        wikrt_val* const pv = wikrt_pval(cx, addr);
        wikrt_val const otag = pv[0];
        if(wikrt_otag_deepsum(otag)) {
            wikrt_val const s0 = (otag >> 8);
            (*inRight) = (3 == (3 & s0));
            wikrt_val const sf = (s0 >> 2);
            if(0 == sf) { // dealloc deepsum
                (*v) = pv[1];
                wikrt_free(cx, WIKRT_CELLSIZE, addr);
            } else { // keep value, reduced one level 
                (*v) = c;
                pv[0] = (sf << 8) | WIKRT_OTAG_DEEPSUM;
            }
            return WIKRT_OK;
        } else if(wikrt_otag_array(otag)) {
            (*inRight) = false;
            (*v) = WIKRT_VOID;
            // probably expand head of array then retry...
            return WIKRT_IMPL;
        } 
    }

    (*inRight) = false;
    (*v) = WIKRT_VOID;
    return WIKRT_TYPE_ERROR;
}

wikrt_err _wikrt_alloc_block(wikrt_cx* cx, wikrt_val* v, char const* abc, size_t len, wikrt_abc_opts opts) 
{
    (*v) = WIKRT_VOID;
    return WIKRT_IMPL;
}


wikrt_err _wikrt_alloc_seal(wikrt_cx* cx, wikrt_val* sv, char const* s, size_t len, wikrt_val v)
{
    bool const validLen = (0 < len) && (len < 64);
    if(!validLen) { (*sv) = WIKRT_VOID; return WIKRT_INVAL; }

    if((':' == s[0]) && (len <= 4)) {
        // WIKRT_OTAG_SEAL_SM: common special case, small discretionary tags
        // represent seal in otag!
        #define TAG(N) ((len > N) ? (((wikrt_val)s[N]) << (8*N)) : 0)
        wikrt_val const tag = TAG(3) | TAG(2) | TAG(1) | WIKRT_OTAG_SEAL_SM;
        if(!wikrt_alloc_cellval(cx, sv, WIKRT_O, tag, v)) { return WIKRT_CXFULL; }
        return WIKRT_OK;
        #undef TAG
    } else {
        // WIKRT_OTAG_SEAL: rare general case, large tags
        wikrt_size const szTotal = WIKRT_CELLSIZE + (wikrt_size) len;
        wikrt_addr dst;
        if(!wikrt_alloc(cx, szTotal, &dst)) {
            (*sv) = WIKRT_VOID;
            return WIKRT_CXFULL;
        }
        (*sv) = wikrt_tag_addr(WIKRT_O, dst);
        wikrt_val* const psv = wikrt_pval(cx,dst);
        psv[0] = (len << 8) | WIKRT_OTAG_SEAL;
        psv[1] = v;
        memcpy((psv + 2), s, len); // copy of sealer text
        return WIKRT_OK;
    }
} 


wikrt_err _wikrt_split_seal(wikrt_cx* cx, wikrt_val sv, char* buff, wikrt_val* v)
{
    (*buff) = 0;
    (*v) = WIKRT_VOID;

    wikrt_addr const addr = wikrt_vaddr(sv);
    wikrt_tag const tag = wikrt_vtag(sv);
    if((WIKRT_O != tag) || (0 == addr)) { return WIKRT_TYPE_ERROR; }
    wikrt_val const* const pv = wikrt_pval(cx, addr);

    if(wikrt_otag_seal_sm(*pv)) {
        wikrt_val const otag = pv[0];
        (*v) = pv[1];
        buff[0] = ':';
        buff[1] = (char)((otag >> 8 ) & 0xFF);
        buff[2] = (char)((otag >> 16) & 0xFF);
        buff[3] = (char)((otag >> 24) & 0xFF);
        buff[4] = 0;
        wikrt_free(cx, WIKRT_CELLSIZE, addr);
        return WIKRT_OK;
    } else if(wikrt_otag_seal(*pv)) {
        size_t const len = (pv[0] >> 8) & 0x3F;
        size_t const allocSz = WIKRT_CELLSIZE + len;
        memcpy(buff, (pv + 2), len);
        buff[len] = 0;
        (*v) = pv[1];
        wikrt_free(cx, allocSz, addr);
        return WIKRT_OK;
    } else { return WIKRT_TYPE_ERROR; }

}

static void wikrt_copy_step_next(wikrt_cx* cx, wikrt_val* lcpy, wikrt_val** dst) 
{
    // basic list is (addr, next) which corresponds to (addr, 0, 1, next)
    // alternative is WIKRT_O ref to (addr, step, count, next) for array-like structures.
    wikrt_addr const addr = wikrt_vaddr(*lcpy);
    wikrt_tag const tag = wikrt_vtag(*lcpy);
    wikrt_val* const node = wikrt_pval(cx, addr);
    if(0 == addr) { (*dst) = NULL; }
    else if(WIKRT_PL == tag) {
        // node → (addr, next)
        (*dst) = wikrt_pval(cx, node[0]);
        (*lcpy) = node[1];
        wikrt_free(cx, WIKRT_CELLSIZE, addr);
    } else if(WIKRT_O == tag) {
        // node → (addr, step, count, next)
        (*dst) = wikrt_pval(cx, node[0]);
        node[2] -= 1;       // reduce count
        node[0] += node[1]; // apply step
        if(0 == node[2]) {
            (*lcpy) = node[3]; // continue with list
            wikrt_free(cx, (2 * WIKRT_CELLSIZE), addr);
        }
    } else {
        fprintf(stderr, "wikrt: invalid copy stack\n");
        abort();
    }
}

static bool wikrt_copy_add_task(wikrt_cx* cx, wikrt_val* lcpy, wikrt_addr a) {
    return wikrt_alloc_cellval(cx, lcpy, WIKRT_PL, a, (*lcpy));
}

static bool wikrt_copy_add_arraytask(wikrt_cx* cx, wikrt_val* lcpy, wikrt_addr a, wikrt_size step, wikrt_size ct) {
    if(1 == ct) { return wikrt_copy_add_task(cx, lcpy, a); }
    else { return wikrt_alloc_dcellval(cx, lcpy, a, step, ct, (*lcpy)); }
}


/** deep copy a structure
 *
 * The 'stack' for copies is represented within the context itself. 
 * Copies for stacks, lists, and arrays is specialized for performance.
 */
wikrt_err _wikrt_copy(wikrt_cx* cx, wikrt_val* dst, wikrt_val const origin, bool const bCopyAff) 
{
    (*dst) = origin;
    wikrt_val lcpy = WIKRT_UNIT_INR;
    do {
        wikrt_val const v0 = (*dst);

        // shallow copies may be left alone
        if(wikrt_copy_shallow(v0)) {
            wikrt_copy_step_next(cx, &lcpy, &dst);
            continue;
        }

        // dst points to a value reference to cx->memory
        wikrt_tag const tag = wikrt_vtag(v0);
        wikrt_addr const addr = wikrt_vaddr(v0);
        wikrt_val const* const pv = wikrt_pval(cx, addr);
        if(WIKRT_O != tag) {

            // tag is WIKRT_P, WIKRT_PL, or WIKRT_PR. Node points to a pair.
            // This is a common case for structured data - lists, stacks, and
            // trees. I'll allocate a 'spine' in one chunk, which optimizes
            // for lists and stacks (and shouldn't hurt other structures).
            wikrt_size const cellCt = 1 + wikrt_spine_length(cx, pv[1]);

            wikrt_addr spine;
            if(!wikrt_alloc(cx, (WIKRT_CELLSIZE * cellCt), &spine)) { return WIKRT_CXFULL; }
            if(!wikrt_copy_add_arraytask(cx, &lcpy, spine, WIKRT_CELLSIZE, cellCt)) { return WIKRT_CXFULL; }
            (*dst) = wikrt_tag_addr(tag, spine);

            wikrt_val const* hd = pv;
            wikrt_addr intraSpine = spine;
            for(wikrt_size ii = cellCt; ii > 1; --ii) {
                wikrt_val* const pintraSpine = wikrt_pval(cx, intraSpine);
                intraSpine += WIKRT_CELLSIZE; 
                pintraSpine[0] = hd[0]; // copied later via arraytask
                pintraSpine[1] = wikrt_tag_addr(wikrt_vtag(hd[1]), intraSpine);
                hd = wikrt_pval(cx, wikrt_vaddr(hd[1])); // next item.
            }
            wikrt_val* const pspineLast = wikrt_pval(cx, intraSpine);
            pspineLast[0] = hd[0]; // last intra-spine value; copied by arraytask
            pspineLast[1] = hd[1]; // end of spine is not an intra-spine reference
            dst = 1 + pspineLast; // copy final value in spine.

        } else { switch(LOBYTE(*pv)) {

            case WIKRT_OTAG_SEAL_SM: // same as DEEPSUM
            case WIKRT_OTAG_DEEPSUM: {
                // (header, value) pairs, referenced via WIKRT_O tag.
                if(!wikrt_alloc_cellval(cx, dst, WIKRT_O, pv[0], pv[1])) { return WIKRT_CXFULL; }
                dst = 1 + wikrt_pval(cx, wikrt_vaddr(*dst)); // copy contained value
            } break;

            case WIKRT_OTAG_BLOCK: {
                // (block-header, opcode-list) with substructural properties
                bool const bPerformCopy = !wikrt_block_aff(pv[0]) || bCopyAff; 
                if(!bPerformCopy) { return WIKRT_TYPE_ERROR; } 
                if(!wikrt_alloc_cellval(cx, dst, WIKRT_O, pv[0], pv[1])) { return WIKRT_CXFULL; }
                dst = 1 + wikrt_pval(cx, wikrt_vaddr(*dst));
            } break;

            case WIKRT_OTAG_OPVAL: {
                // value operator with potential latent copyability checking
                bool const latentAff = (0 != (WIKRT_OPVAL_LAZYKF & *pv));
                if(latentAff || bCopyAff) {
                    if(!wikrt_alloc_cellval(cx, dst, WIKRT_O, pv[0], pv[1])) { return WIKRT_CXFULL; }
                    dst = 1 + wikrt_pval(cx, wikrt_vaddr(*dst));
                } else {
                    // suppress affine checks for this value.
                    wikrt_err const st = _wikrt_copy(cx, dst, (*dst), true);
                    if(WIKRT_OK != st) { return st; }
                    wikrt_copy_step_next(cx, &lcpy, &dst);
                }
            } break;

            case WIKRT_OTAG_ARRAY: {
                // TODO: copy the array
                return WIKRT_IMPL;
            } break;

            case WIKRT_OTAG_BIGINT: {
                // (size&sign, array of 32-bit digits in 0..999999999)
                wikrt_size const nDigits = (*pv) >> 9;
                wikrt_size const szAlloc = sizeof(wikrt_val) + (nDigits * sizeof(uint32_t));
                wikrt_addr copy;
                if(!wikrt_alloc(cx, szAlloc, &copy)) { return WIKRT_CXFULL; }
                memcpy(wikrt_pval(cx, copy), pv, szAlloc); // copy the binary data
                (*dst) = wikrt_tag_addr(WIKRT_O, copy); 
                wikrt_copy_step_next(cx, &lcpy, &dst);
            } break;

            case WIKRT_OTAG_SEAL: {
                // (len, value, token). token is adjacent to cell
                wikrt_size const len = ((*pv) >> 8) & 0x3F; // 1..63 is valid
                wikrt_size const szAlloc = WIKRT_CELLSIZE + len;
                wikrt_addr copy;
                if(!wikrt_alloc(cx, szAlloc, &copy)) { return WIKRT_CXFULL; }
                memcpy(wikrt_pval(cx, copy), pv, szAlloc);
                (*dst) = wikrt_tag_addr(WIKRT_O, copy);
                dst = 1 + wikrt_pval(cx, copy); // copy the sealed value
            } break;

            case WIKRT_OTAG_STOWAGE: {
                // TODO: copy stowed value; should be shallow copy (refct?)
                return WIKRT_IMPL;
            } break;

            default: {
                fprintf(stderr, u8"wikrt: copy unrecognized value: %u→(%u,%u...)\n", (*dst), pv[0], pv[1]);
                return WIKRT_IMPL;
            }
        }}
    } while(NULL != dst);
    assert(WIKRT_UNIT_INR == lcpy);
    return WIKRT_OK;
}

static void wikrt_drop_step_next(wikrt_cx* cx, wikrt_val* ldrop, wikrt_val* tgt) 
{
    // basic list is (val, next); will need specialization for arrays.
    wikrt_tag const tag = wikrt_vtag(*ldrop);
    wikrt_addr const addr = wikrt_vaddr(*ldrop);
    wikrt_val* const node = wikrt_pval(cx, addr);
    if(0 == addr) { (*tgt) = WIKRT_VOID; return; }
    else if(WIKRT_PL == tag) {
        (*tgt) = node[0];
        (*ldrop) = node[1];
        wikrt_free(cx, WIKRT_CELLSIZE, addr);
    } else {
        fprintf(stderr, "wikrt: invalid drop stack\n");
        abort();
    }
}


/** destroy a structure and recover memory
 *
 * To avoid busting the C-level stack, the stack for objects to drop is
 * represented within the context itself. 
 *
 * For the moment, I'm favoring a cascading destruction. This does risk
 * high latency for large structures. I could switch to lazy deletion
 * later if ever this becomes a problem.
 */
wikrt_err _wikrt_drop(wikrt_cx* cx, wikrt_val v, bool const bDropRel) 
{
    wikrt_val ldrop = WIKRT_UNIT_INR; // list of values to drop
    do {
        if(wikrt_copy_shallow(v)) {
            if(WIKRT_UNIT_INR == ldrop) { return WIKRT_OK; }
            wikrt_drop_step_next(cx, &ldrop, &v);
            continue;
        }

        // value references cx->memory
        wikrt_tag const tag = wikrt_vtag(v);
        wikrt_addr const addr = wikrt_vaddr(v);
        wikrt_val* const pv = wikrt_pval(cx, addr);
    
        if(WIKRT_O != tag) {

            // tag is WIKRT_P, WIKRT_PL, or WIKRT_PR; addr points to cell.
            // This is common case for structured data (lists, stacks, trees).
            v = pv[1]; // first delete spine of stack or list.
            pv[1] = ldrop;
            ldrop = wikrt_tag_addr(WIKRT_PL, addr);

        } else { switch(LOBYTE(*pv)) {

            case WIKRT_OTAG_SEAL_SM: // same as DEEPSUM
            case WIKRT_OTAG_DEEPSUM: {
                // (header, value) pair. 
                v = pv[1]; // free contained value
                wikrt_free(cx, WIKRT_CELLSIZE, addr);
            } break;


            case WIKRT_OTAG_BLOCK: {
                // (block-header, opcode-list) with substructural properties
                bool const bPerformDrop = !wikrt_block_rel(pv[0]) || bDropRel;
                if(!bPerformDrop) { return WIKRT_TYPE_ERROR; } 
                v = pv[1];
                wikrt_free(cx, WIKRT_CELLSIZE, addr);
            } break;

            case WIKRT_OTAG_OPVAL: {
                bool const latentRel = (0 != (WIKRT_OPVAL_LAZYKF & *pv));
                if(latentRel || bDropRel) {
                    v = pv[1]; 
                    wikrt_free(cx, WIKRT_CELLSIZE, addr);
                } else {
                    // suppress relevance checking for value
                    wikrt_err const st = _wikrt_drop(cx, v, true);
                    if(WIKRT_OK != st) { return st; }
                    wikrt_drop_step_next(cx, &ldrop, &v);
                }
            } break;

            case WIKRT_OTAG_ARRAY: {
                // TODO: drop values from array.

                return WIKRT_IMPL;
            } break;

            case WIKRT_OTAG_BIGINT: {
                wikrt_size const nDigits = (*pv) >> 9;
                wikrt_size const szAlloc = sizeof(wikrt_val) + (nDigits * sizeof(uint32_t));
                wikrt_free(cx, szAlloc, addr);
                wikrt_drop_step_next(cx, &ldrop, &v);
            } break;

            case WIKRT_OTAG_SEAL: {
                v = pv[1];
                wikrt_size const len = ((*pv) >> 8) & 0x3F; // 1..63 is valid
                wikrt_size const szAlloc = WIKRT_CELLSIZE + len;
                wikrt_free(cx, szAlloc, addr);
            } break;

            case WIKRT_OTAG_STOWAGE: {
                // TODO: clear stowage from todo-lists and ephemeron tables

                return WIKRT_IMPL;
            } break;

            default: {
                fprintf(stderr, u8"wikrt: drop unrecognized value: %u→(%u,%u...)\n", v, pv[0], pv[1]);
                return WIKRT_IMPL;
            }
        }}
    } while(true);
}

/** Stowage will need some special considerations, eventually.
 *
 * Latent or lazy stowage is essential for performance reasons. We must
 * not perform stowage until we feel some space pressure, or until we
 * are planning to commit a transaction. 
 */

wikrt_err _wikrt_stow(wikrt_cx* cx, wikrt_val* out) 
{
    return WIKRT_OK;
}


