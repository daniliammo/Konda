#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void){ long N=1048576; char*a=calloc(N,1),*b=calloc(N,1); long k=0;
  for(int i=0;i<300;i++) if(memcmp(a,b,N)==0) k++;
  printf("%ld\n",k); return a&&b?0:1; }
