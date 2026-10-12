/*
 * blas_probe -- DGEMM (BLAS3) and DGEMV (BLAS2) rates, one MPI rank per core.
 *
 *     blas_probe [N] [M] [reps]      N: DGEMM order, M: DGEMV order
 *
 * Each rank multiplies its own matrices, single-threaded, so the figure is
 * per-core arithmetic (DGEMM) and per-core memory streaming (DGEMV) with every
 * core of the allocation busy at once -- the way an MPI code meets them.
 * Rank 0 prints `key: value` lines that the contract's extract reads.
 *
 * The answer is checkable: A is all 1, B is all 2, so every element of
 * C = A*B is 2N, and every element of y = A*x with x all 1 is M.  A wrong
 * kernel -- the risk when a library picks its code at run time -- shows as
 * valid: false rather than as a fast number.
 *
 * WHICH LIBRARY RAN
 *
 * The probe is linked against OpenBLAS, but any library that defines the
 * CBLAS symbols and is loaded first answers the calls instead -- MKL from the
 * host, preloaded through APPTAINERENV_LD_PRELOAD, is how the seam study
 * compares the two in one image.  So the probe does not assume: it asks the
 * dynamic linker which file defines cblas_dgemm, and reports that library.
 * For MKL it adds MKL's version, its CNR "auto branch", and -- the concrete
 * answer -- which of its per-ISA kernel libraries it actually loaded
 * (libmkl_avx512, libmkl_avx2, ... or libmkl_def, its generic library),
 * read from /proc/self/maps after the timed calls.  On a non-Intel CPU MKL
 * reports its branch as AUTO, which says nothing; the loaded library does.
 * For OpenBLAS, the kernel set.  Only the library that ran is
 * described, so a row cannot carry OpenBLAS's kernel name for MKL's numbers.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <mpi.h>
#include <cblas.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char *openblas_get_corename(void);
char *openblas_get_config(void);

static double now(void) { return MPI_Wtime(); }

/* MKL's names for its code paths: mkl_types.h, MKL_CBWR_*. */
static const char *mkl_branch_name(int b)
{
    switch (b) {
    case 2:  return "AUTO";      /* what MKL reports on a non-Intel CPU */
    case 3:  return "COMPATIBLE";
    case 4:  return "SSE2";
    case 6:  return "SSSE3";
    case 7:  return "SSE4_1";
    case 8:  return "SSE4_2";
    case 9:  return "AVX";
    case 10: return "AVX2";
    case 11: return "AVX512_MIC";
    case 12: return "AVX512";
    case 13: return "AVX512_MIC_E1";
    case 14: return "AVX512_E1";
    case 15: return "AVX10";
    default: return "unknown";
    }
}

/* Which loaded file defines cblas_dgemm, and what to say about it. */
static void describe_blas(void)
{
    Dl_info info;
    void *sym = dlsym(RTLD_DEFAULT, "cblas_dgemm");
    const char *file = (sym && dladdr(sym, &info) && info.dli_fname) ? info.dli_fname : "unknown";
    printf("BLAS library: %s\n", file);

    void (*mkl_version)(char *, int) =
        (void (*)(char *, int))dlsym(RTLD_DEFAULT, "MKL_Get_Version_String");
    int (*mkl_branch)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "MKL_CBWR_Get_Auto_Branch");
    if (strstr(file, "mkl") && mkl_version) {
        char buf[256] = "";
        mkl_version(buf, (int)sizeof buf);
        printf("BLAS: mkl\n");
        printf("MKL version: %s\n", buf);
        printf("MKL branch: %s\n", mkl_branch ? mkl_branch_name(mkl_branch()) : "unknown");
        /* libmkl_<isa>.so: the kernels MKL dispatched to.  Not libmkl_vml_*
         * (the vector math library) and not the plumbing: rt, core, the
         * interface and threading layers. */
        FILE *maps = fopen("/proc/self/maps", "r");
        char line[1024], kernels[256] = "";
        while (maps && fgets(line, sizeof line, maps)) {
            char *name = strrchr(line, '/');
            if (!name || !strstr(line, "r-xp") || strncmp(name, "/libmkl_", 8)) continue;
            name += 8;
            if (!strncmp(name, "vml_", 4) || !strncmp(name, "rt.", 3) || !strncmp(name, "core.", 5)
                || !strncmp(name, "intel_", 6) || !strncmp(name, "gf_", 3)
                || !strncmp(name, "sequential.", 11) || !strncmp(name, "gnu_thread.", 11)
                || !strncmp(name, "intel_thread.", 13)) continue;
            char *dot = strchr(name, '.');
            if (dot) *dot = '\0';
            if (!strstr(kernels, name)) {
                if (*kernels) strncat(kernels, ",", sizeof kernels - strlen(kernels) - 1);
                strncat(kernels, name, sizeof kernels - strlen(kernels) - 1);
            }
        }
        if (maps) fclose(maps);
        printf("MKL kernels: %s\n", *kernels ? kernels : "unknown");
    } else if (strstr(file, "openblas")) {
        printf("BLAS: openblas\n");
        printf("Core: %s\n", openblas_get_corename());
        printf("Config: %s\n", openblas_get_config());
    } else {
        printf("BLAS: unknown\n");
    }
}

static int cmp(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(int argc, char **argv)
{
    int rank, size;
    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    int n    = argc > 1 ? atoi(argv[1]) : 2048;
    int m    = argc > 2 ? atoi(argv[2]) : 8192;
    int reps = argc > 3 ? atoi(argv[3]) : 5;
    if (n < 1 || m < 1 || reps < 1) MPI_Abort(MPI_COMM_WORLD, 2);

    double *a = malloc(sizeof(double) * n * n), *b = malloc(sizeof(double) * n * n),
           *c = malloc(sizeof(double) * n * n);
    double *g = malloc(sizeof(double) * m * m), *x = malloc(sizeof(double) * m),
           *y = malloc(sizeof(double) * m);
    if (!a || !b || !c || !g || !x || !y) MPI_Abort(MPI_COMM_WORLD, 3);
    for (long i = 0; i < (long)n * n; i++) { a[i] = 1.0; b[i] = 2.0; c[i] = 0.0; }
    for (long i = 0; i < (long)m * m; i++) g[i] = 1.0;
    for (int i = 0; i < m; i++) { x[i] = 1.0; y[i] = 0.0; }

    /* One untimed call each, so page faults and the library's first-call
     * setup are not timed. */
    cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans, n, n, n, 1.0, a, n, b, n, 0.0, c, n);
    cblas_dgemv(CblasColMajor, CblasNoTrans, m, m, 1.0, g, m, x, 1, 0.0, y, 1);

    double t_mm = 1e30, t_mv = 1e30;
    for (int r = 0; r < reps; r++) {
        MPI_Barrier(MPI_COMM_WORLD);
        double t0 = now();
        cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans, n, n, n, 1.0, a, n, b, n, 0.0, c, n);
        double t = now() - t0;
        if (t < t_mm) t_mm = t;
    }
    for (int r = 0; r < reps * 4; r++) {
        MPI_Barrier(MPI_COMM_WORLD);
        double t0 = now();
        cblas_dgemv(CblasColMajor, CblasNoTrans, m, m, 1.0, g, m, x, 1, 0.0, y, 1);
        double t = now() - t0;
        if (t < t_mv) t_mv = t;
    }

    int ok = fabs(c[0] - 2.0 * n) < 1e-9 * n && fabs(c[(long)n * n - 1] - 2.0 * n) < 1e-9 * n
          && fabs(y[0] - m) < 1e-9 * m && fabs(y[m - 1] - m) < 1e-9 * m;

    /* Per-rank best times; report the median rank, so one slow core is
     * visible but does not set the figure. */
    double mm = 2.0 * n * (double)n * n / t_mm / 1e9;
    double mv_gbs = 8.0 * (double)m * m / t_mv / 1e9;
    double *all_mm = rank == 0 ? malloc(sizeof(double) * size) : NULL;
    double *all_mv = rank == 0 ? malloc(sizeof(double) * size) : NULL;
    MPI_Gather(&mm, 1, MPI_DOUBLE, all_mm, 1, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    MPI_Gather(&mv_gbs, 1, MPI_DOUBLE, all_mv, 1, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    int all_ok = 0;
    MPI_Reduce(&ok, &all_ok, 1, MPI_INT, MPI_MIN, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        qsort(all_mm, size, sizeof(double), cmp);
        qsort(all_mv, size, sizeof(double), cmp);
        double sum_mm = 0, sum_mv = 0;
        for (int i = 0; i < size; i++) { sum_mm += all_mm[i]; sum_mv += all_mv[i]; }
        printf("blas_probe: ranks %d, dgemm order %d, dgemv order %d, best of %d\n", size, n, m, reps);
        describe_blas();
        printf("DGEMM GFLOPS per rank (median): %.3f\n", all_mm[size / 2]);
        printf("DGEMM GFLOPS per rank (min): %.3f\n", all_mm[0]);
        printf("DGEMM GFLOPS total: %.3f\n", sum_mm);
        printf("DGEMV GB/s per rank (median): %.3f\n", all_mv[size / 2]);
        printf("DGEMV GB/s total: %.3f\n", sum_mv);
        printf("Valid: %s\n", all_ok ? "true" : "false");
    }
    MPI_Finalize();
    return 0;
}
