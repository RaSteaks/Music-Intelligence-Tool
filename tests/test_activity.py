"""One local activity workflow: real audio, missing stems and partial coverage."""
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"MusicIntelligenceTool/MusicIntelligenceTool/Backend"))
from activity_analysis import analyze_activity


class ActivityTests(unittest.TestCase):
    def test_activity_pipeline_preserves_time_and_reports_coverage(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            sr = 16000
            t = np.arange(sr * 6)/sr
            vocals = .2*np.sin(2*np.pi*220*t)
            vocals[(t < 1) | ((t >= 2) & (t < 4)) | (t >= 5)] = 0
            drums = np.zeros(len(t))
            for start in (1, 1.5, 2, 2.5):
                window = np.arange(int(sr*.1))/sr
                drums[int(start*sr):int(start*sr)+len(window)] = .3*np.sin(2*np.pi*100*window)
            drums[int(4.9*sr):int(4.9*sr)+100] = .4
            source, vocal_file, drum_file = root/'mix.wav', root/'vocals.wav', root/'drums.wav'
            sf.write(source, vocals+drums, sr, subtype='FLOAT')
            sf.write(vocal_file, np.column_stack((vocals, -vocals)), sr, subtype='FLOAT')
            sf.write(drum_file, drums, sr, subtype='FLOAT')
            scratch = root/'scratch'; scratch.mkdir()
            stems = {'vocals': str(vocal_file), 'drums': str(drum_file)}
            result = analyze_activity(source, 1, 5, stems, scratch, 120)
            self.assertEqual(len(result['warnings']), 1)  # Bass was not available, not detected as absent.
            by_source = {name: [(r['start'], r['end']) for r in result['marks']
                                if r['fields']['event_type']['suggested'] == name]
                         for name in ('vocals', 'drums', 'silence')}
            np.testing.assert_allclose(by_source['vocals'], [(1, 2), (4, 5)], atol=.11)
            np.testing.assert_allclose(by_source['drums'], [(1, 2.6)], atol=.11)
            np.testing.assert_allclose(by_source['silence'], [(2.6, 4)], atol=.11)
            self.assertEqual({row['source'] for row in result['coverage']}, {'silence', 'vocals', 'drums'})
            self.assertTrue(all(row['start'] == 1 and row['end'] == 5 for row in result['coverage']))

            # Re-running with unavailable material reports what was actually measured.
            sf.write(vocal_file, vocals[:sr*2], sr)
            drum_file.write_bytes(b'not audio')
            partial = analyze_activity(source, 1, 5, stems, scratch)
            self.assertTrue(any('只覆盖' in warning for warning in partial['warnings']))
            self.assertTrue(any('无法解码' in warning for warning in partial['warnings']))
            self.assertIn({'source':'vocals', 'start':1, 'end':2}, partial['coverage'])
            self.assertFalse(any(row['source'] == 'drums' for row in partial['coverage']))


if __name__ == '__main__':
    unittest.main()
