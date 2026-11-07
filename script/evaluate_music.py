"""Fixed, local MIR calibration matrix. No cloud calls or model downloads.

Run: .venv/bin/python script/evaluate_music.py --output tmp/music-evaluation
Targets are defined before analysis; synthesized signals supply independent
physical ground truth, not a reimplementation of the estimators.
"""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import sys
import time

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT/"MusicIntelligenceTool/MusicIntelligenceTool/Backend"
sys.path.insert(0, str(BACKEND))
from harmony_analysis import analyze_harmony
from repetition_analysis import analyze_repetition
from rhythm_analysis import analyze_rhythm

TARGETS = {"solo_pitch_accuracy": .90, "mixed_pitch_accuracy": .75, "silent_pitch_fraction": .05,
           "chord_duration_accuracy": .85, "repeat_recall": 1.0, "noise_repeats": 0,
           "beat_f1": .75, "tempo_error_bpm": 5, "melody_seconds_per_audio_second": 4,
           "regional_key_accuracy": 1.0, "melody_motif_matches": 1}


def tone(midi, duration, sr=22050, amplitude=.2):
    t = np.arange(round(duration*sr))/sr
    phase = 2*np.pi*440*2**((midi-69)/12)*t
    wave = amplitude*(np.sin(phase)+.2*np.sin(2*phase)+.07*np.sin(3*phase))
    ramp = min(round(.02*sr), len(wave)//2)
    if ramp:
        wave[:ramp] *= np.linspace(0, 1, ramp)
        wave[-ramp:] *= np.linspace(1, 0, ramp)
    return wave


def evaluate(folder, melody_only=False, recorded=None):
    folder.mkdir(parents=True, exist_ok=True)
    cases = []
    sr = 22050

    def save(name, wave):
        file = folder/(name+".wav")
        sf.write(file, wave, sr, subtype="FLOAT")
        return file

    def record(name, metrics, passed, seconds):
        cases.append({"case": name, "metrics": metrics, "passed": bool(passed), "elapsed_s": round(seconds, 3)})
        print(name, "PASS" if passed else "FAIL", metrics, flush=True)

    def finish():
        report={"targets":TARGETS,"platform":platform.platform(),"cases":cases,"passed":all(row["passed"] for row in cases),
                "scope":"Deterministic calibration; not a real-song benchmark or a cloud model evaluation."}
        (folder/"report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2))
        return report["passed"]

    melody = np.concatenate([np.zeros(sr)] + [tone(midi, 1, amplitude=.3) for midi in (69, 72, 76, 74, 69)] + [np.zeros(sr)])
    background = np.zeros(len(melody))
    background[sr:6*sr] = tone(45, 5, amplitude=.15) + sum(tone(midi, 5, amplitude=.04) for midi in (57, 60, 64))
    for name, wave, threshold in (("solo_pitch", melody, TARGETS["solo_pitch_accuracy"]),
                                   ("mixed_pitch", melody+background, TARGETS["mixed_pitch_accuracy"])):
        file = save(name, wave)
        input_file, output_file = folder/(name+".input.json"), folder/(name+".result.json")
        input_file.write_text(json.dumps({"path": str(file.resolve()), "duration": 7, "marks": [], "stems": {}}))
        started = time.monotonic()
        with (folder/(name+".log")).open("w") as log:
            subprocess.run([str(ROOT/".venv-music/bin/python"), str(BACKEND/"analysis_worker.py"), "melody",
                            str(input_file), str(output_file), str(ROOT), "0", "7"], check=True, stdout=log, stderr=log)
        elapsed = time.monotonic()-started
        rows = json.loads(output_file.read_text())["marks"]
        pitches = [row for row in rows if row["kind"] == "pitch"]
        correct, total = 0, 0
        for index, midi in enumerate((69, 72, 76, 74, 69)):
            for t in np.arange(index+1.15, index+1.85, .05):
                found = next((row for row in pitches if row["start"] <= t < row["end"]), None)
                correct += bool(found and abs(found["metrics"]["midi_pitch"]-midi) <= .5)
                total += 1
        silence = sum(max(0, min(row["end"], .8)-max(row["start"], 0)) + max(0, min(row["end"], 7)-max(row["start"], 6.2)) for row in pitches)/1.6
        accuracy = correct/total
        record(name, {"pitch_accuracy_50c": accuracy, "silent_pitch_fraction": silence, "time_ratio": elapsed/7},
               accuracy >= threshold and silence <= TARGETS["silent_pitch_fraction"] and elapsed/7 <= TARGETS["melody_seconds_per_audio_second"], elapsed)

    motif_notes=(69,72,76,74,69)
    motif=np.concatenate([np.zeros(sr)] + [tone(midi,.5,amplitude=.3) for midi in motif_notes] +
                         [np.zeros(round(sr*.6))] + [tone(midi+2,.5,amplitude=.3) for midi in motif_notes] + [np.zeros(sr)])
    file=save("melody_motif",motif);length=len(motif)/sr
    input_file,output_file=folder/"motif.input.json",folder/"motif.result.json"
    input_file.write_text(json.dumps({"path":str(file.resolve()),"duration":length,"marks":[],"stems":{}}));started=time.monotonic()
    with (folder/"motif.log").open("w") as log:
        subprocess.run([str(ROOT/".venv-music/bin/python"),str(BACKEND/"analysis_worker.py"),"melody",str(input_file),str(output_file),str(ROOT),"0",str(length)],check=True,stdout=log,stderr=log)
    matches=[row for row in json.loads(output_file.read_text())["marks"] if row["kind"]=="melody_motif"]
    record("melody_motif",{"matches":len(matches),"shift":matches[0]["metrics"]["transpose_semitones"] if matches else None},
           len(matches)>=TARGETS["melody_motif_matches"] and matches[0]["metrics"]["transpose_semitones"]==2,time.monotonic()-started)

    if melody_only:
        return finish()

    chords = [("C", [48, 52, 55]), ("Am", [45, 48, 52]), ("Fmaj7", [53, 57, 60, 64]), ("G7", [43, 47, 50, 53])]
    wave = np.concatenate([sum(tone(note, 2, amplitude=.12) for note in notes) for _, notes in chords])
    file = save("chords", wave)
    beats = [{"kind":"beat", "start":float(t)} for t in np.arange(0, 8, .5)]
    started = time.monotonic(); result = analyze_harmony(file, 0, 8, {"marks":beats})
    (folder/"chords.result.json").write_text(json.dumps(result))
    correct = 0
    for index, (label, _) in enumerate(chords):
        correct += sum(max(0, min(row["end"], index*2+2)-max(row["start"], index*2)) for row in result["marks"]
                       if row["kind"] == "chord" and row["fields"]["label"]["suggested"].split("/")[0] == label)
    record("chords", {"duration_accuracy":correct/8}, correct/8 >= TARGETS["chord_duration_accuracy"], time.monotonic()-started)

    phrase = [60, 64, 67, 64, 62, 65, 69, 65]
    a = np.concatenate([tone(note, .5) for note in phrase])
    b = np.concatenate([tone(note, .5) for note in [70, 66, 61, 69, 63, 71, 66, 60]])
    varied = np.concatenate([tone(note+2, .6) for note in phrase])
    file = save("repetition", np.concatenate((a,b,a,varied)))
    sections = [{"kind":"section", "id":str(i), "start":lo, "end":hi} for i,(lo,hi) in enumerate([(0,4),(4,8),(8,12),(12,16.8)])]
    started=time.monotonic(); result=analyze_repetition(file,16.8,{"marks":sections})
    (folder/"repetition.result.json").write_text(json.dumps(result))
    found = {round(row["start"]):row for row in result["marks"]}
    recall = sum(t in found for t in (8,12))/2
    shift = found.get(12,{}).get("metrics",{}).get("transpose_semitones")
    record("repetition", {"recall":recall,"variant_shift":shift,"unrelated_matches":int(4 in found)},
           recall >= TARGETS["repeat_recall"] and shift == 2 and 4 not in found, time.monotonic()-started)
    noise = save("noise", np.random.default_rng(341).normal(0,.1,sr*8))
    started=time.monotonic(); result=analyze_repetition(noise,8,{"marks":sections[:2]})
    noise_input,noise_output=folder/"noise.input.json",folder/"noise.result.json"
    noise_input.write_text(json.dumps({"path":str(noise.resolve()),"duration":8,"marks":[],"stems":{}}))
    with (folder/"noise.log").open("w") as log:
        subprocess.run([str(ROOT/".venv-music/bin/python"),str(BACKEND/"analysis_worker.py"),"melody",str(noise_input),str(noise_output),str(ROOT),"0","8"],check=True,stdout=log,stderr=log)
    pitched=sum(row["end"]-row["start"] for row in json.loads(noise_output.read_text())["marks"] if row["kind"]=="pitch")/8
    record("noise_rejection", {"repetitions":len(result["marks"]),"pitched_fraction":pitched}, len(result["marks"]) <= TARGETS["noise_repeats"] and pitched <= TARGETS["silent_pitch_fraction"], time.monotonic()-started)

    clicks = np.zeros(sr*12); expected=np.arange(1,11,.5)
    pulse = np.random.default_rng(512).normal(size=int(sr*.025))*np.exp(-np.arange(int(sr*.025))/(sr*.006))
    for index,t in enumerate(expected):
        lo=int(t*sr);clicks[lo:lo+len(pulse)] += pulse*(.8 if index%4==0 else .5)
        lo=int((t+1/3)*sr); clicks[lo:lo+len(pulse)] += pulse*.18
    file=save("rhythm",clicks)
    started=time.monotonic(); result=analyze_rhythm(file,0,12,{"marks":[]})
    (folder/"rhythm.result.json").write_text(json.dumps(result))
    actual=[row["start"] for row in result["marks"] if row["kind"] == "rhythm_beat"]
    matched=sum(any(abs(t-b)<.07 for b in actual) for t in expected)
    precision=sum(any(abs(t-b)<.07 for b in expected) for t in actual)/max(1,len(actual))
    recall=matched/len(expected); f1=2*precision*recall/max(1e-9,precision+recall)
    summary=next((row for row in result["marks"] if row["kind"]=="rhythm_summary"),{})
    error=abs(summary.get("metrics",{}).get("tempo_bpm",0)-120)
    record("rhythm", {"beat_f1":f1,"tempo_error_bpm":error}, f1 >= TARGETS["beat_f1"] and error <= TARGETS["tempo_error_bpm"], time.monotonic()-started)
    known=[{"kind":"beat","start":float(t)} for t in expected]+[{"kind":"downbeat","start":float(t)} for t in expected[::4]]
    started=time.monotonic(); result=analyze_rhythm(file,0,12,{"marks":known})
    summary=next(row for row in result["marks"] if row["kind"]=="rhythm_summary")
    metrics=summary["metrics"]
    record("meter_and_swing", {"beats_per_bar":metrics.get("beats_per_bar"),"swing_ratio":metrics.get("swing_ratio")},
           metrics.get("beats_per_bar")==4 and 1.5 <= metrics.get("swing_ratio",0) <= 2.7, time.monotonic()-started)

    cadence = [([48,52,55],4),([53,57,60],2),([43,47,50,53],2),([48,52,55],4)]
    wave=np.concatenate([sum(tone(note+shift,length,sr=sr,amplitude=.12) for note in notes)
                         for shift in (0,2) for notes,length in cadence])
    file=save("modulation",wave)
    started=time.monotonic()
    result=analyze_harmony(file,0,24,{"marks":[{"kind":"section","start":0,"end":12},{"kind":"section","start":12,"end":24}]})
    (folder/"modulation.result.json").write_text(json.dumps(result))
    keys=[row["fields"]["label"]["suggested"] for row in result["marks"] if row["kind"]=="key_region"]
    accuracy=sum(a==b for a,b in zip(keys,["C major","D major"]))/2
    record("regional_tonality",{"key_regions":keys,"accuracy":accuracy,"change_candidates":sum(row["kind"]=="modulation" for row in result["marks"])},
           accuracy >= TARGETS["regional_key_accuracy"],time.monotonic()-started)

    variable=np.zeros(sr*13)
    for t in np.concatenate((np.arange(1,6,.5),np.arange(6,12,2/3))):
        lo=int(t*sr);variable[lo:lo+len(pulse)]+=pulse*.7
    file=save("tempo_change",variable);started=time.monotonic()
    result=analyze_rhythm(file,0,13,{"marks":[]})
    (folder/"tempo_change.result.json").write_text(json.dumps(result))
    tempos=[row["metrics"]["tempo_bpm"] for row in result["marks"] if row["kind"]=="tempo"]
    record("tempo_change",{"local_tempos":tempos}, all(any(abs(value-target)<=TARGETS["tempo_error_bpm"] for value in tempos) for target in (90,120)),time.monotonic()-started)

    if recorded:
        import librosa
        y, sample_rate = sf.read(recorded, dtype="float32")
        if y.ndim == 2: y = y.mean(axis=1)
        file = folder/"recorded.wav";sf.write(file,y,sample_rate)
        length=len(y)/sample_rate
        request={"path":str(file.resolve()),"duration":length,"marks":[],"stems":{}}
        input_file=folder/"recorded.input.json";output_file=folder/"recorded.result.json"
        input_file.write_text(json.dumps(request));started=time.monotonic()
        with (folder/"recorded.log").open("w") as log:
            subprocess.run([str(ROOT/".venv-music/bin/python"),str(BACKEND/"analysis_worker.py"),"melody",str(input_file),str(output_file),str(ROOT),"0",str(length)],check=True,stdout=log,stderr=log)
        rows=json.loads(output_file.read_text())["marks"]
        estimate=[row for row in rows if row["kind"]=="pitch"]
        f0, voiced, _=librosa.pyin(y,fmin=65,fmax=2093,sr=sample_rate,hop_length=256)
        deltas=[]
        for index,value in enumerate(f0):
            if not voiced[index] or not np.isfinite(value): continue
            t=index*256/sample_rate
            row=next((row for row in estimate if row["start"]<=t<row["end"]),None)
            if row: deltas.append(abs(1200*np.log2(row["metrics"]["frequency_hz"]/value)))
        cases.append({"case":"recorded_trumpet","passed":bool(estimate),"metrics":{"pitch_frames":len(estimate),"median_agreement_cents":float(np.median(deltas)) if deltas else None},
                      "elapsed_s":time.monotonic()-started,"scope":"Unlabelled real recording; pYIN agreement is consistency, not ground-truth accuracy."})
        print('recorded_trumpet',cases[-1]['metrics'],flush=True)

    return finish()


if __name__ == "__main__":
    parser=argparse.ArgumentParser();parser.add_argument("--output",type=Path,default=ROOT/"tmp/music-evaluation")
    parser.add_argument("--melody-only", action="store_true")
    parser.add_argument("--recorded", type=Path)
    args=parser.parse_args()
    sys.exit(0 if evaluate(args.output, args.melody_only, args.recorded) else 1)
