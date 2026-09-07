#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
int main(void){ long N=1048576; unsigned char*a=calloc(N,1); uint64_t h=0;
  for(int r=0;r<300;r++){ uint64_t x=14695981039346656037ULL;
    for(long i=0;i<N;i++){ x^=a[i]; x*=1099511628211ULL; } h+=x; }
  printf("%lu\n",h); return a?0:1; }
