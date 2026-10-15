// pointer-chase latency: random cyclic walk over SIZE bytes at 64B... use 256B stride slots to defeat adjacent prefetch
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <sys/mman.h>
int main(int c, char**v){
  size_t size=(size_t)atol(v[1])<<20, slot=256, n=size/slot; long iters=atol(v[2]);
  char*buf=mmap(0,size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_POPULATE,-1,0);
  madvise(buf,size,MADV_NOHUGEPAGE);
  size_t*perm=malloc(n*sizeof(size_t)); for(size_t i=0;i<n;i++)perm[i]=i;
  srand(1); for(size_t i=n-1;i>0;i--){size_t j=((size_t)rand()<<16^rand())%(i+1); size_t t=perm[i];perm[i]=perm[j];perm[j]=t;}
  for(size_t i=0;i<n;i++) *(char**)(buf+perm[i]*slot)=buf+perm[(i+1)%n]*slot;
  char*p=buf+perm[0]*slot; for(long i=0;i<n;i++) p=*(char**)p;
  struct timespec a,b; clock_gettime(CLOCK_MONOTONIC,&a);
  for(long i=0;i<iters;i++) p=*(char**)p;
  clock_gettime(CLOCK_MONOTONIC,&b);
  printf("%.1f ns/load (%zu MiB) %p\n",((b.tv_sec-a.tv_sec)*1e9+(b.tv_nsec-a.tv_nsec))/iters,size>>20,(void*)p);
}
