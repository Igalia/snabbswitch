/*
** VM profiling.
** Copyright (C) 2016 Luke Gorrie. See Copyright Notice in luajit.h
*/

#define lj_vmprofile_c
#define LUA_CORE

#define _GNU_SOURCE 1
#include <stdio.h>
#include <assert.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <signal.h>
#include <ucontext.h>
#undef _GNU_SOURCE

#include "lj_err.h"
#include "lj_obj.h"
#include "lj_dispatch.h"
#include "lj_jit.h"
#include "lj_trace.h"
#include "lj_vmprofile.h"

static struct {
  global_State *g;
  struct sigaction oldsa;
} state;

/* -- State that the application can manage via FFI ----------------------- */

static VMProfile *profile;      /* Current counters */

/* How much memory to allocate for profiler counters. */
int vmprofile_get_profile_size() {
  return sizeof(VMProfile);
}

/* Set the memory where the next samples will be counted. 
   Size of the memory must match vmprofile_get_profile_size(). */
void vmprofile_set_profile(void *counters) {
  profile = (VMProfile*)counters;
  profile->magic = 0x1d50f007;
  profile->major = 3;
  profile->minor = 0;
}

/* -- Signal handler ------------------------------------------------------ */

/* Signal handler: bumps one counter. */
static void vmprofile_signal(int sig, siginfo_t *si, void *data)
{
  if (profile != NULL) {
    lua_State *L = gco2th(gcref(state.g->cur_L));
    int vmstate = state.g->vmstate;
    int trace = 0;
    /* Get the relevant trace number */
    if (vmstate > 0) {
      /* JIT mcode */
      trace = vmstate;
    } else if (~vmstate == LJ_VMST_GC) {
      /* JIT GC */
      trace = state.g->gcvmstate;
    } else if (~vmstate == LJ_VMST_INTERP && state.g->lasttrace > 0) {
      /* Interpreter entered at the end of some trace */
      trace = state.g->lasttrace;
    }
    if (trace > 0) {
      /* JIT mode: Bump a global counter and a per-trace counter. */
      int bucket = trace > LJ_VMPROFILE_TRACE_MAX ? 0 : trace;
      VMProfileTraceCount *count = &profile->trace[bucket];
      GCtrace *T = traceref(L2J(L), (TraceNo)trace);
      intptr_t ip = (intptr_t)((ucontext_t*)data)->uc_mcontext.gregs[REG_RIP];
      ptrdiff_t mcposition = ip - (intptr_t)T->mcode;
      printf("trace %d interp %d\n", trace, ~vmstate == LJ_VMST_INTERP);
      if (~vmstate == LJ_VMST_GC) {
        profile->vm[LJ_VMST_JGC]++;
        count->gc++;
      } else if (~vmstate == LJ_VMST_INTERP) {
        profile->vm[LJ_VMST_INTERP]++;
        count->interp++;
      } else if ((mcposition < 0) || (mcposition >= T->szmcode)) {
        profile->vm[LJ_VMST_FFI]++;
        count->ffi++;
      } else if ((T->mcloop != 0) && (mcposition >= T->mcloop)) {
        profile->vm[LJ_VMST_LOOP]++;
        count->loop++;
      } else {
        profile->vm[LJ_VMST_HEAD]++;
        count->head++;
      }
    } else {
      /* Interpreter mode: Just bump a global counter. */
      profile->vm[~vmstate]++;
    }
  }
}

static void start_timer(int interval)
{
  struct itimerval tm;
  struct sigaction sa;
  tm.it_value.tv_sec = tm.it_interval.tv_sec = interval / 1000;
  tm.it_value.tv_usec = tm.it_interval.tv_usec = (interval % 1000) * 1000;
  setitimer(ITIMER_PROF, &tm, NULL);
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sa.sa_sigaction = vmprofile_signal;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGPROF, &sa, &state.oldsa);
}

static void stop_timer()
{
  struct itimerval tm;
  tm.it_value.tv_sec = tm.it_interval.tv_sec = 0;
  tm.it_value.tv_usec = tm.it_interval.tv_usec = 0;
  setitimer(ITIMER_PROF, &tm, NULL);
  sigaction(SIGPROF, NULL, &state.oldsa);
}

/* -- Lua API ------------------------------------------------------------- */

LUA_API int luaJIT_vmprofile_open(lua_State *L, const char *str)
{
  int fd;
  void *ptr;
  if (((fd = open(str, O_RDWR|O_CREAT, 0666)) != -1) &&
      ((ftruncate(fd, sizeof(VMProfile))) != -1) &&
      ((ptr = mmap(NULL, sizeof(VMProfile), PROT_READ|PROT_WRITE,
                   MAP_SHARED, fd, 0)) != MAP_FAILED)) {
    memset(ptr, 0, sizeof(VMProfile));
    setlightudV(L->base, checklightudptr(L, ptr));
  } else {
    setnilV(L->base);
  }
  if (fd != -1) {
    close(fd);
  }
  return 1;
}

LUA_API int luaJIT_vmprofile_close(lua_State *L, void *ud)
{
  munmap(ud, sizeof(VMProfile));
  return 0;
}

LUA_API int luaJIT_vmprofile_select(lua_State *L, void *ud)
{
  setlightudV(L->base, checklightudptr(L, profile));
  profile = (VMProfile *)ud;
  return 1;
}

LUA_API int luaJIT_vmprofile_start(lua_State *L)
{
  memset(&state, 0, sizeof(state));
  state.g = G(L);
  start_timer(1);               /* Sample every 1ms */
  return 0;
}

LUA_API int luaJIT_vmprofile_stop(lua_State *L)
{
  stop_timer();
  return 0;
}

