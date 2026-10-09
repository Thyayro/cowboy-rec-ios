// fxblur — DESFOQUE DE MOVIMENTO do Cowboy Rec na VPS (modo Render do app).
// A MESMA conta do shader do iPhone (LutBaker.swift) e da prévia (MotionBlur.swift): para cada quadro com linha no arquivo
// de efeitos (.fx.csv: t_ms,zoom,mx,my,n1[,n2,roll]), cada pixel lê amostras ao longo do caminho — giro no eixo (roll) e
// escala radial a partir do centro (zoom) mais o deslocamento do giro — e fica com a média. Rastro longo em DUAS etapas
// (0.9.0): n1 leituras no caminho inteiro, deslocadas pelo ruído intercalado do pixel, e depois n2 leituras no passo da 1ª
// (n1×n2 amostras = rastro liso de zoom de edição). Quadros sem linha passam intactos (cópia direta).
// Coordenadas: as do quadro do sensor, SEM a rotação de exibição (o ffmpeg de leitura usa -noautorotate).
// uso: fxblur W H fps arquivo.fx [pts.txt|-] [threads] < yuv420p10le > yuv420p10le
// Compilar (host Ubuntu, roda no contêiner Alpine): gcc -O3 -ffast-math -march=native -static -pthread -o fxblur fxblur.c -lm
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { double t; float z, mx, my, roll; int n1, n2; } Fx;
typedef struct { float z, mx, my, roll; int n; int jit; } Pass;
static Fx *fx; static int nfx;
static double *pts; static int npts;

typedef struct { const uint16_t *src; uint16_t *dst; int w, h, ls; float aspect; int y0, y1; Pass f; } Job;

static int cmpfx(const void *a, const void *b) { double x = ((const Fx *)a)->t, y = ((const Fx *)b)->t; return x < y ? -1 : x > y; }
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

// leitura bilinear em coordenada normalizada com borda presa (= sampler linear clamp_to_edge do Metal)
static inline float sample(const uint16_t *p, int w, int h, float u, float v) {
  float x = u * w - 0.5f, y = v * h - 0.5f;
  x = fminf(fmaxf(x, 0.0f), (float)(w - 1));
  y = fminf(fmaxf(y, 0.0f), (float)(h - 1));
  int ix = (int)x, iy = (int)y; float ax = x - ix, ay = y - iy;
  int ix1 = ix + 1 < w ? ix + 1 : ix, iy1 = iy + 1 < h ? iy + 1 : iy;
  const uint16_t *r0 = p + (size_t)iy * w, *r1 = p + (size_t)iy1 * w;
  float a = r0[ix] + ((float)r0[ix1] - r0[ix]) * ax;
  float b = r1[ix] + ((float)r1[ix1] - r1[ix]) * ax;
  return a + (b - a) * ay;
}

static void *run(void *arg) {
  Job *j = (Job *)arg; const Pass f = j->f; const int n = f.n; const float A = j->aspect;
  for (int y = j->y0; y < j->y1; y++) {
    for (int x = 0; x < j->w; x++) {
      float jj = 0;
      if (f.jit) {   // ruído intercalado do pixel (no croma: o do 1º pixel de luma do bloco, como o shader)
        float fj = 0.06711056f * (float)(x * j->ls) + 0.00583715f * (float)(y * j->ls);
        jj = 52.9829189f * (fj - floorf(fj)); jj = jj - floorf(jj) - 0.5f;
      }
      float dx0 = ((x + 0.5f) / j->w - 0.5f) * A, dy0 = (y + 0.5f) / j->h - 0.5f, acc = 0;
      for (int i = 0; i < n; i++) {
        float uu = (i + 0.5f + jj) / n - 0.5f, a = f.z * uu;
        float s = fabsf(a) < 0.2f ? 1 + a * (1 + a * (0.5f + a * (1.0f / 6))) : expf(a);
        float dx = dx0, dy = dy0;
        if (f.roll != 0) { float r = f.roll * uu, c = cosf(r), sn = sinf(r); dx = dx0 * c - dy0 * sn; dy = dx0 * sn + dy0 * c; }
        acc += sample(j->src, j->w, j->h, 0.5f + dx / A * s + f.mx * uu, 0.5f + dy * s + f.my * uu);
      }
      int v = (int)lrintf(acc / n);
      j->dst[(size_t)y * j->w + x] = (uint16_t)(v < 0 ? 0 : v > 1023 ? 1023 : v);
    }
  }
  return NULL;
}

static void plane(const uint16_t *src, uint16_t *dst, int w, int h, int ls, float aspect, Pass f, int threads) {
  pthread_t th[16]; Job jobs[16];
  if (threads < 1) threads = 1;
  if (threads > 16) threads = 16;
  for (int t = 0; t < threads; t++) {
    jobs[t] = (Job){ src, dst, w, h, ls, aspect, h * t / threads, h * (t + 1) / threads, f };
    pthread_create(&th[t], NULL, run, &jobs[t]);
  }
  for (int t = 0; t < threads; t++) pthread_join(th[t], NULL);
}

static size_t readall(void *buf, size_t n) { size_t got = 0; while (got < n) { size_t r = fread((char *)buf + got, 1, n - got, stdin); if (r == 0) break; got += r; } return got; }

int main(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "uso: fxblur W H fps arquivo.fx [pts.txt|-] [threads]\n"); return 2; }
  int W = atoi(argv[1]), H = atoi(argv[2]); double fps = atof(argv[3]);
  int threads = argc > 6 ? atoi(argv[6]) : 2;
  if (W <= 0 || H <= 0 || fps <= 0) { fprintf(stderr, "tamanho/fps inválido\n"); return 2; }
  FILE *ff = fopen(argv[4], "r"); if (!ff) { fprintf(stderr, "sem arquivo de efeitos\n"); return 2; }
  int cap = 1024; fx = malloc(sizeof(Fx) * cap); char line[256];
  while (fgets(line, sizeof line, ff)) {
    Fx e = { 0 }; e.n2 = 1;
    int got = sscanf(line, "%lf,%f,%f,%f,%d,%d,%f", &e.t, &e.z, &e.mx, &e.my, &e.n1, &e.n2, &e.roll);
    if (got < 5 || e.n1 < 2) continue;
    if (got < 6 || e.n2 < 1) e.n2 = 1;
    if (e.n1 > 32) e.n1 = 32;
    if (e.n2 > 32) e.n2 = 32;
    if (nfx == cap) { cap *= 2; fx = realloc(fx, sizeof(Fx) * cap); }
    fx[nfx++] = e;
  }
  fclose(ff); qsort(fx, nfx, sizeof(Fx), cmpfx);
  if (argc > 5 && strcmp(argv[5], "-")) {
    FILE *fp = fopen(argv[5], "r");
    if (fp) { int pc = 4096; pts = malloc(sizeof(double) * pc); double v;
      while (fscanf(fp, "%lf", &v) == 1) { if (npts == pc) { pc *= 2; pts = realloc(pts, sizeof(double) * pc); } pts[npts++] = v; }
      fclose(fp); qsort(pts, npts, sizeof(double), cmpd); }
  }
  int cw = (W + 1) / 2, ch = (H + 1) / 2;
  float aspect = (float)W / (float)H;
  size_t ys = (size_t)W * H, cs = (size_t)cw * ch, total = ys + 2 * cs;
  uint16_t *in = malloc(total * 2), *out = malloc(total * 2), *mid = malloc(total * 2);
  static char obuf[1 << 22]; setvbuf(stdout, obuf, _IOFBF, sizeof obuf);
  double half = 500.0 / fps; int fi = 0, done = 0; size_t k = 0;
  while (readall(in, total * 2) == total * 2) {
    double t = (npts > fi ? pts[fi] - pts[0] : fi / fps) * 1000;
    while (k + 1 < (size_t)nfx && fx[k + 1].t <= t) k++;   // linha mais perto (as duas vizinhas)
    const Fx *best = NULL;
    for (size_t c = k; c <= k + 1 && c < (size_t)nfx; c++) if (fabs(fx[c].t - t) <= half && (!best || fabs(fx[c].t - t) < fabs(best->t - t))) best = &fx[c];
    if (best) {
      Pass p1 = { best->z, best->mx, best->my, best->roll, best->n1, 1 };
      Pass c1 = p1; c1.n = p1.n > 2 ? (p1.n + 1) / 2 + 1 : p1.n;   // croma tem metade da resolução: metade das leituras
      if (best->n2 > 1) {
        // 1ª etapa (caminho inteiro, com ruído) -> meio; 2ª etapa (o passo da 1ª, sem ruído) -> saída
        float kk = (float)best->n1;
        Pass p2 = { best->z / kk, best->mx / kk, best->my / kk, best->roll / kk, best->n2, 0 };
        Pass c2 = p2; c2.n = p2.n > 2 ? (p2.n + 1) / 2 + 1 : p2.n;
        plane(in, mid, W, H, 1, aspect, p1, threads);
        plane(in + ys, mid + ys, cw, ch, 2, aspect, c1, threads);
        plane(in + ys + cs, mid + ys + cs, cw, ch, 2, aspect, c1, threads);
        plane(mid, out, W, H, 1, aspect, p2, threads);
        plane(mid + ys, out + ys, cw, ch, 2, aspect, c2, threads);
        plane(mid + ys + cs, out + ys + cs, cw, ch, 2, aspect, c2, threads);
      } else {
        plane(in, out, W, H, 1, aspect, p1, threads);
        plane(in + ys, out + ys, cw, ch, 2, aspect, c1, threads);
        plane(in + ys + cs, out + ys + cs, cw, ch, 2, aspect, c1, threads);
      }
      fwrite(out, 2, total, stdout); done++;
    } else fwrite(in, 2, total, stdout);
    fi++;
    if (fi % 60 == 0) fprintf(stderr, "quadro=%d efeito=%d\n", fi, done);
  }
  fflush(stdout);
  fprintf(stderr, "fim quadros=%d efeito=%d linhas=%d\n", fi, done, nfx);
  return 0;
}
