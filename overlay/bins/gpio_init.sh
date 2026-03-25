#!/bin/bash
# =============================================================================
# gpio_init.sh — инициализация GPIO, LED и питания mSATA
# Запускается при старте через gpio-netdev.service
# =============================================================================
modprobe ledtrig-netdev 2>/dev/null || true

# LED_PWR — включаем постоянно
echo default-on > /sys/class/leds/LED_PWR/trigger 2>/dev/null || true

# LED_LTE и LED_LTE_1 → eth0 (link + tx + rx)
for led in LED_LTE LED_LTE_1; do
    [ -d /sys/class/leds/${led} ] || continue
    echo netdev  > /sys/class/leds/${led}/trigger     2>/dev/null || true
    echo eth0    > /sys/class/leds/${led}/device_name 2>/dev/null || true
    echo 1       > /sys/class/leds/${led}/link        2>/dev/null || true
    echo 1       > /sys/class/leds/${led}/tx          2>/dev/null || true
    echo 1       > /sys/class/leds/${led}/rx          2>/dev/null || true
done

# Питание mSATA через GPIO PA7
echo 7   > /sys/class/gpio/export           2>/dev/null || true
echo out > /sys/class/gpio/gpio7/direction  2>/dev/null || true
echo 1   > /sys/class/gpio/gpio7/value      2>/dev/null || true
