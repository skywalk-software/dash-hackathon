import io
import unittest
import wave
from app import validate_wav

class AudioContractTests(unittest.TestCase):
    def wav(self, channels=1, rate=16000):
        output = io.BytesIO()
        with wave.open(output, 'wb') as file:
            file.setnchannels(channels)
            file.setsampwidth(2)
            file.setframerate(rate)
            file.writeframes(b'\0\0' * channels * 1600)
        return output.getvalue()

    def test_valid_microphone_audio(self):
        samples, duration = validate_wav(self.wav())
        self.assertEqual(len(samples), 3200)
        self.assertAlmostEqual(duration, 0.1)

    def test_rejects_stereo_and_wrong_rate(self):
        for data in [self.wav(channels=2), self.wav(rate=48000)]:
            with self.assertRaises(ValueError):
                validate_wav(data)

    def test_rejects_truncated_audio(self):
        with self.assertRaises(ValueError):
            validate_wav(self.wav()[:-20])

if __name__ == '__main__':
    unittest.main()
