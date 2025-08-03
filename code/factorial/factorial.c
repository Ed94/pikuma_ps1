#include <stdio.h>

int factorial(int num) {
  int i;      // $t1
  int j;      // $t2
  int temp;   // $t3
  int sum;    // $t4
 
  temp = 1;
  sum = 1;
  i = 1;
  while (i <= num) {
    sum = 0;
    j = 0;
    while (j < i) {
      sum += temp;
      j++;
    }
    temp = sum;
    i++;
  }
  return sum;
}

int main() {
  printf("fac(%d) = %d\n", 6, factorial(6));
  return 0;
}
