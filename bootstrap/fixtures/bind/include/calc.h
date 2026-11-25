#define CALC_LIMIT 8
#define CALC_MASK (1 << 3)
#define CALC_RATIO 0.5
#define CALC_FN(x) ((x) + 1)
#define CALC_EMPTY

typedef unsigned long calc_word;

struct calc_point { int x; int y; };
enum calc_color { CALC_RED, CALC_GREEN };

extern const int calc_table_size;
extern int calc_counter;

static int calc_static(int a);

void calc_walk(int (*visit)(int, int), void *ctx);
unsigned long calc_len(const char *s);
int calc_printf(const char *fmt, ...);
void *calc_alloc(unsigned long n);
