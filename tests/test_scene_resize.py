"""Receiving scene adapters and interpolation invalidation, without device claims."""
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def body(source, signature):
    """Extract the current balanced method/function, including its signature."""
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


@unittest.skipUnless(platform.system() == 'Darwin', 'Receiving adapter fixtures require Foundation')
class SceneResizeTests(unittest.TestCase):
    def run_fixture(self, fixture, sanitizer):
        """Build and run source-derived methods with deterministic synthetic peers."""
        with tempfile.TemporaryDirectory(prefix='odyssey-scene-resize-') as temporary:
            path = Path(temporary)
            source, binary = path/'fixture.m', path/'fixture'
            source.write_text(fixture)
            command = ['xcrun','clang','-fobjc-arc','-fblocks','-O1','-g','-Wall','-Wextra','-Werror',
                       '-fsanitize='+sanitizer,'-I',str(ROOT/'dm/host'),'-framework','Foundation','-framework','CoreGraphics',str(source),'-o',str(binary)]
            compiled = subprocess.run(command,capture_output=True,text=True,timeout=60)
            self.assertEqual(compiled.returncode,0,compiled.stdout+compiled.stderr)
            result = subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            return result.stdout

    def test_actual_frontend_and_touch_only_reset(self):
        frontend = (ROOT/'dm/ios/Sources/front_ios.m').read_text()
        pad = (ROOT/'dm/ios/Sources/DmGamepad.m').read_text()
        fixture = (ROOT/'dm/ios/tests/t_scene_resize.m.in').read_text()
        start = frontend.index('@interface DmGameView')
        end = frontend.index('@interface DmRootVC')
        root_end = frontend.index('@implementation DmRootVC',end)
        fixture = fixture.replace('/* GAME_VIEW */',frontend[start:end])
        fixture = fixture.replace('/* ROOT_INTERFACE */',frontend[end:root_end])
        fixture = fixture.replace('/* ROOT_LAYOUT */',body(frontend,'- (void)viewDidLayoutSubviews'))
        fixture = fixture.replace('/* ROOT_SAFE_AREA */',body(frontend,'- (void)viewSafeAreaInsetsDidChange'))
        fixture = fixture.replace('/* TOUCH_GEOMETRY_HOOK */',body(pad,'void dm_gamepad_geometry_changed(void)'))
        self.assertIn('74 actual frontend adapter geometry transitions',self.run_fixture(fixture,'address,undefined,float-divide-by-zero'))

    def test_actual_resize_epoch_preserves_native_retirement(self):
        source = (ROOT/'dm/gfx/nvn/nvn_framegen_queue.inc').read_text()
        fixture = (ROOT/'dm/ios/tests/t_resize_epoch.m.in').read_text()
        fixture = fixture.replace('/* INVALIDATE */',body(source,'static void fg_invalidate_locked(void)'))
        fixture = fixture.replace('/* GEOMETRY_HOOK */',body(source,'void mtl_present_geometry_changed(void)'))
        self.assertIn('2001 notifications',self.run_fixture(fixture,'thread'))

    def test_resize_hook_has_no_gpu_waits_or_cross_thread_history_calls(self):
        source = (ROOT/'dm/gfx/nvn/nvn_framegen_queue.inc').read_text()
        hook = body(source,'void mtl_present_geometry_changed(void)')
        for unsafe in ('resetHistory','drainGPU','suspended','pthread_cond_wait','g_pq_done','g_pq_read','g_pq_inflight','g_fg_capture_busy'):
            self.assertNotIn(unsafe,hook)
        # Existing serial processing admits only the current epoch, resets its
        # own history and rejects old results after a concurrent invalidation.
        worker = body(source,'static void *fg_process_main(void *arg)')
        self.assertIn('if (pending.epoch != epoch) continue;',worker)
        self.assertIn('if (history_epoch && history_epoch != epoch) [g_fg resetHistory];',worker)
        self.assertIn('pending.epoch == g_fg_epoch',worker)


if __name__ == '__main__':
    unittest.main()
