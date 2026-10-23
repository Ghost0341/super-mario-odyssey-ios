"""Receiving source-frame geometry through queued presentation and interpolation."""
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def body(source, signature):
    """Extract the actual balanced method/function, without copying its behavior."""
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


@unittest.skipUnless(platform.system() == 'Darwin', 'Native receiving source fixture requires Foundation')
class FrameAspectTests(unittest.TestCase):
    def test_actual_frame_metadata_viewport_and_history(self):
        mtl = (ROOT/'dm/gfx/nvn/nvn_mtl.m').read_text()
        queue = (ROOT/'dm/gfx/nvn/nvn_framegen_queue.inc').read_text()
        model = (ROOT/'dm/gfx/nvn/nvn_framegen.m').read_text()
        fixture = (ROOT/'dm/ios/tests/t_frame_aspect.m.in').read_text()
        for marker, source, signature in [
            ('VIEWPORT',mtl,'static MTLViewport present_viewport('),
            ('INVALIDATE',queue,'static void fg_invalidate_locked(void)'),
            ('ADMIT_GEOMETRY',queue,'static uint64_t fg_admit_geometry_locked('),
            ('OUTPUT',model,'static NVNFrameGenOutput *fg_output('),
            ('PROCESS',model,'- (NSArray<NVNFrameGenOutput *> *)processCapture:'),
        ]:
            fixture = fixture.replace('/* '+marker+' */', body(source,signature))
        with tempfile.TemporaryDirectory(prefix='odyssey-frame-aspect-') as temporary:
            p=Path(temporary); source=p/'fixture.m'; binary=p/'fixture';source.write_text(fixture)
            compiled=subprocess.run(['xcrun','clang','-std=gnu11','-fobjc-arc','-O1','-g','-Wall','-Wextra','-Werror',
                '-fsanitize=address,undefined,float-divide-by-zero','-I',str(ROOT/'dm/gfx/nvn'),
                '-framework','Foundation',str(source),'-o',str(binary)],capture_output=True,text=True,timeout=60)
            self.assertEqual(compiled.returncode,0,compiled.stdout+compiled.stderr)
            ran=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
            self.assertEqual(ran.returncode,0,ran.stdout+ran.stderr)
            self.assertIn('1000 queued geometry transitions',ran.stdout)

    def test_source_geometry_propagation(self):
        source=(ROOT/'dm/gfx/nvn/nvn_mtl.m').read_text()
        queue=(ROOT/'dm/gfx/nvn/nvn_framegen_queue.inc').read_text()
        model=(ROOT/'dm/gfx/nvn/nvn_framegen.m').read_text()
        enqueue=body(source,'static uint64_t present_enqueue(const tex_t *t, double period, const int crop[4], uint64_t ev_val) {')
        self.assertIn('logical_aspect = dm_odyssey_display_source_aspect()',enqueue)
        self.assertIn('geometry_generation = dm_odyssey_display_source_generation()',enqueue)
        self.assertIn('.logical_aspect=logical_aspect, .geometry_generation=geometry_generation',enqueue)
        viewport=body(source,'static MTLViewport present_viewport(')
        for mutable in ('dm_odyssey_display_enabled','dm_odyssey_display_aspect','dw / dh'):
            self.assertNotIn(mutable,viewport)
        self.assertIn('logicalAspect:it.logical_aspect geometryGeneration:it.geometry_generation',queue)
        self.assertIn('update.drawable.texture.height, out.logicalAspect)',queue)
        self.assertIn('epoch = fg_admit_geometry_locked(it.logical_aspect, it.geometry_generation)',queue)
        self.assertIn('epoch, source.logicalAspect, source.geometryGeneration)',model)
        for signature in ('static int present_encode(id<MTLCommandBuffer> cb, id<MTLTexture> src, id<MTLTexture> dst, const int crop[4], double logical_aspect) {',
                          'static int present_encode_m4(id<MTL4CommandBuffer> cb, id<MTLTexture> src, id<MTLTexture> dst, const int crop[4], int uv_i, double logical_aspect) {'):
            self.assertIn('present_viewport(cw, ch, dw, dh, logical_aspect)',body(source,signature))
        helper=body(queue,'static uint64_t fg_admit_geometry_locked(')
        for forbidden in ('g_pq_done','g_pq_read','g_pq_inflight','drainGPU','resetHistory','waitUntilCompleted'):
            self.assertNotIn(forbidden,helper)


if __name__=='__main__':unittest.main()
