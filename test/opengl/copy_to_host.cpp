#include <Halide.h>
#include <stdio.h>

using namespace Halide;

int main() {
    Func gpu("gpu"), cpu("cpu");
    Var x, y, c;

    // Fill buffer using GLSL
    gpu(x, y, c) = cast<uint8_t>(select(c == 0, 10*x + y,
                                        select(c == 1, 127, 12)));
    gpu.glsl(x, y, c, 3);
    gpu.compute_root();

    // This should trigger a copy_to_host operation
    cpu(x, y, c) = gpu(x, y, c);

    Image<uint8_t> out(10, 10, 3);
    cpu.realize(out);

    for (int y=0; y<out.height(); y++) {
        for (int x=0; x<out.width(); x++) {
            if (!(out(x, y, 0) == 10*x+y && out(x, y, 1) == 127 && out(x, y, 2) == 12)) {
                fprintf(stderr, "Incorrect pixel (%d, %d, %d) at x=%d y=%d.\n",
                        out(x, y, 0), out(x, y, 1), out(x, y, 2),
                        x, y);
                return 1;
            }
        }
    }
    return 0;
}
