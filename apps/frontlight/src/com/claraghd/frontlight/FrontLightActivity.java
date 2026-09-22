package com.claraghd.frontlight;

import android.app.Activity;
import android.os.Bundle;
import android.provider.Settings;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.SeekBar;
import android.widget.TextView;

/**
 * Front light control for the Kobo Clara HD.
 *
 * The stock control is a pop-up slider that dismisses itself immediately,
 * which is unusable on e-ink. This is a plain activity that stays open:
 * a slider plus coarse steps and presets, writing the system brightness
 * setting (PowerManagerService observes it and drives the LM3630A through
 * the lights HAL).
 */
public class FrontLightActivity extends Activity implements SeekBar.OnSeekBarChangeListener {

    private static final int MAX = 255;

    private SeekBar mSeek;
    private TextView mValue;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.main);

        mSeek = (SeekBar) findViewById(R.id.seek);
        mValue = (TextView) findViewById(R.id.value);
        mSeek.setOnSeekBarChangeListener(this);

        setPresetOnClick(R.id.off, 0);
        setPresetOnClick(R.id.max, MAX);
        setPresetOnClick(R.id.p25, MAX / 4);
        setPresetOnClick(R.id.p50, MAX / 2);
        setPresetOnClick(R.id.p75, (MAX * 3) / 4);
        setStepOnClick(R.id.minus, -13);
        setStepOnClick(R.id.plus, 13);
    }

    @Override
    protected void onResume() {
        super.onResume();
        // Manual mode: an auto-brightness setting would fight every change.
        try {
            Settings.System.putInt(getContentResolver(),
                    Settings.System.SCREEN_BRIGHTNESS_MODE,
                    Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL);
        } catch (Exception ignored) {
        }
        mSeek.setProgress(readBrightness());
        showValue(readBrightness());
    }

    private int readBrightness() {
        try {
            return Settings.System.getInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS);
        } catch (Settings.SettingNotFoundException e) {
            return 0;
        }
    }

    private void setPresetOnClick(int id, final int level) {
        ((Button) findViewById(id)).setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                mSeek.setProgress(level);
                apply(level);
            }
        });
    }

    private void setStepOnClick(int id, final int delta) {
        ((Button) findViewById(id)).setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                int level = clamp(readBrightness() + delta);
                mSeek.setProgress(level);
                apply(level);
            }
        });
    }

    private static int clamp(int level) {
        return level < 0 ? 0 : (level > MAX ? MAX : level);
    }

    private void apply(int level) {
        level = clamp(level);
        Settings.System.putInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, level);
        // Also apply to this window, so the change is visible while dragging
        // even before PowerManagerService picks the setting up.
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.screenBrightness = level / (float) MAX;
        getWindow().setAttributes(lp);
        showValue(level);
    }

    private void showValue(int level) {
        mValue.setText(Math.round(level * 100f / MAX) + "%");
    }

    public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
        if (fromUser) {
            apply(progress);
        }
    }

    public void onStartTrackingTouch(SeekBar seekBar) {
    }

    public void onStopTrackingTouch(SeekBar seekBar) {
        apply(seekBar.getProgress());
    }
}
