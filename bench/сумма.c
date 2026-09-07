#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
int main(void){ int N=1000000; int32_t*a=malloc(N*sizeof*a);
  for(int i=0;i<N;i++) a[i]=i;
  int64_t s=0; for(int r=0;r<60;r++) for(int i=0;i<N;i++) s+=(int64_t)a[i];
  printf("%ld\n",(long)s); return 0; }
