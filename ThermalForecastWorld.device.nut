// Thermal Forecast World
// Copyright @{get_year()}, Tony Smith
// @version @{get_version()}
// @build @{update_build()}

// ********** IMPORTS **********
//#require "WS2812.class.nut:3.0.0"
@include "ws2812.device.lib.nut"

// If you are NOT using Builder or a similar tool, replace the following @include statement(s)
// with the contents of the named file(s):
@include "submodules/Location/location.class.nut"            // Source: https://github.com/smittytone/Location
@include "submodules/generic-squirrel/disconnect.nut"        // Source: https://github.com/smittytone/generic
@include "submodules/generic-squirrel/utilities.nut"         // Source: https://github.com/smittytone/generic
@include "submodules/generic-squirrel/crashreporter.nut"     // Source: https://github.com/smittytone/generic


// ********** CONSTANTS **********
const MAX_BRIGHT = 255;
const MAX_TEMP = 30.0;
const MIN_TEMP = -10.0;
const RECONNECT_TIME = 61;
const RECONNECT_TIMEOUT = 31;


// ********** GLOBAL VARIABLES **********
local pixels = null;
local locator = null;
local tempData = null;
local pulseTimer = null;
local osVersion = 0.0;
local delta = 1;
local indicatorPixel = 0;
local brightness = 0.1;
local mid = (MAX_TEMP + math.abs(MIN_TEMP)) / 2.0;
local debug = true;
local isOn = true;
local isTopUp = true;
local isDisconnected = false;
local isConnecting = false;
local startColour = [MAX_BRIGHT,0,0];
local disconnectedColour = [0,0,MAX_BRIGHT];
local connectingColour = [MAX_BRIGHT,0,MAX_BRIGHT];


// ********** FUNCTIONS **********
function showTemperature(tempString) {
    // Record the passed in temperature data
    tempData = tempString != null ? tempString : tempData;

    // Only proceed if the display is active
    if (isOn) {
        // Cancel pulsing now that we have received a value
        if (pulseTimer != null) {
            imp.cancelwakeup(pulseTimer);
            pulseTimer = null;
        }

        // Switch off the LEDs in visible sequence
        down();

        // Pause for applause
        imp.sleep(0.4);

        // Extract individual temperatures from the string, which
        // will be something like "30.0:20.0:10.0:0.0:-10.0". This
        // gives 'tempArray' = ["30.0", "20.0", "10.0", "0.0", "-10.0"]
        local tempArray = split(tempString, ":");

        // Switch on the LEDs in visible sequence, reversed this time
        for (local i = 0 ; i < 5 ; i++) {
            setPixel((isTopUp ? i : 4 - i), tempArray[i]);
            imp.sleep(0.2);
        }

        //if (debug) pixels.set((isTopUp ? 0 : 4), [64,0,0]).draw();
    }
}

function down() {
    // Switch the LEDs off one by one from the top to the bottom
    // with a pause in between to indicate change to the user
    for (local i = 0 ; i < 5 ; i++) {
        pixels.set((isTopUp ? 4 - i : i), [0,0,0]).draw();
        imp.sleep(0.2);
    }
}

function startPulse() {
    // Runs a single red light up and down the LED array
    // when there is no temperature data to display
    if (isOn) {
        pixels.fill([0,0,0]);
        indicatorPixel = ((indicatorPixel < 4) ? indicatorPixel + 1 : 0);
        pixels.set((isTopUp ? indicatorPixel : 4 - indicatorPixel), setColour(startColour)).draw();
        pulseTimer = imp.wakeup(1.0, startPulse);
    }
}

function disconnectedPulse() {
    // Runs a single unlit pixel up the LED array over the
    // current temperature data to indicate disconnected state
    if (isOn) {
      local tempArray = split(tempData, ":");
      for (local i = 0 ; i < 5 ; i++) setPixel((isTopUp ? i : 4 - i), tempArray[i]);
      indicatorPixel = indicatorPixel + delta;
      if ((indicatorPixel == 4 && delta == 1) || (indicatorPixel == 0 && delta == -1)) delta = delta * -1;
      local colour = isConnecting ? connectingColour : disconnectedColour;
      pixels.set((isTopUp ? indicatorPixel : 4 - indicatorPixel), setColour(colour)).draw();
      pulseTimer = imp.wakeup(0.5, disconnectedPulse);
    }
}

function setPixel(index, value) {
    local col = [0,0,0];
    local temp = value.tofloat() + math.abs(MIN_TEMP).tofloat();

    // Scale red proportionally to temp, from mid to max
    col[0] = (MAX_BRIGHT.tofloat() / mid) * (temp - mid);
    if (col[0] < 0) col[0] = 0;
    if (col[0] > MAX_BRIGHT) col[0] = MAX_BRIGHT;

    // Scale green proportionally to temp from min + 1 to mid, inversely from mid to max -1
    col[1] = MAX_BRIGHT - ((MAX_BRIGHT.tofloat() / (mid - 1)) * (math.abs(temp - mid - 1)));
    if (col[1] < 0) col[1] = 0;
    if (col[1] > MAX_BRIGHT) col[1] = MAX_BRIGHT;

    // Scale blue inversely to temp, from min to mid
    col[2] = MAX_BRIGHT - ((MAX_BRIGHT.tofloat() / mid) * temp);
    if (col[2] < 0) col[2] = 0;
    if (col[2] > MAX_BRIGHT) col[2] = MAX_BRIGHT;

    // Apply brightness setting to each colour component
    col[0] = (col[0] * brightness).tointeger();
    col[1] = (col[1] * brightness).tointeger();
    col[2] = (col[2] * brightness).tointeger();

    // server.log(format("Temp: %0.2f -> [%d,%d,%d]", temp - 10, col[0], col[1], col[2]));

    // Set current pixel’s color and pause
    pixels.set(index, col).draw();
}

function setColour(colour) {
    // Called to convert a raw colour value into a brightness modulated value
    // Start with a default output of black
    local output = [0,0,0];
    foreach (index, hue in colour) {
        if (hue > 0) output[index] = (hue * brightness).tointeger();
    }
    return output;
}

// ********** CONNECTION/DISCONNECTION FUNCTIONS **********
function disconnectionHandler(event) {
    // Called if the server connection is broken or re-established
    if ("message" in event && debug) server.log("Connection Manager: " + event.message);

    if ("type" in event) {
        if (event.type == "disconnected") {
            isDisconnected = true;
            isConnecting = false;

            // Show the 'device is disconnected' indicator
            if (tempData != null && pulseTimer == null) {
                delta = 1;
                indicatorPixel = -1;
                disconnectedPulse();
            }
        }

        if (event.type == "connecting") isConnecting = true;

        if (event.type == "connected") {
            isDisconnected = false;
            isConnecting = false;

            // Tell the agent we're back online
            agent.send("ready", true);

            // Stop the 'device is disconnected' indicator
            if (pulseTimer != null) {
                imp.cancelwakeup(pulseTimer);
                pulseTimer = null;
            }
        }
    }
}


// ********** RUNTIME START **********

// Load in generic boot message code
// If you are NOT using Builder or a similar tool, replace the following @include statement(s)
// with the contents of the named file(s):
@if BUILD_TYPE == "debug"
@include "submodules/generic-squirrel/bootmessage.nut"   // Source code: https://github.com/smittytone/generic
@endif

// Store the version number for later use
osVersion = bootinfo.version().tofloat();

// Set up the crash reporter
crashReporter.init();

// Set up the disconnection manager
disconnectionManager.eventCallback = disconnectionHandler;
disconnectionManager.reconnectDelay = RECONNECT_TIME;
disconnectionManager.reconnectTimeout = RECONNECT_TIMEOUT;
disconnectionManager.start();

// Instantiate objects
pixels = WS2812(hardware.spi257, 5);
locator = Location();

// Prime the device to process incoming forecast data
agent.on("show.temps", showTemperature);

// Prime the device to process incoming commands...
// ...reboot
agent.on("do.reboot", function(dummy) {
    // Do a reboot: clear the display then restart Squirrel
    pixels.fill([0,0,0]).draw();
    if (osVersion < 38.0) {
        server.restart();
    } else {
        imp.reset();
    }
});

// ...set LED brightness
agent.on("set.bright", function(brightnessValue) {
    // Convert relayed brightness value to range 0.02 - 0.2
    // NOTE This is used to divide down a colur value: eg. 255.0 -> 5.1-51.0
    brightness = (1.0 * brightnessValue) / 50.0;
    if (debug) server.log(format("LED brightness set to %.2f", brightness));
    if (!pulseTimer && tempData) showTemperature(tempData);
});

// ...turn the LEDs on or off
agent.on("set.light", function(state) {
    // If the sent state == the current state, bail
    if (state == isOn) return;
    isOn = state;
    if (!isOn) {
        // Turn the LEDs off
        if (pulseTimer != null) {
            imp.cancelwakeup(pulseTimer);
            pulseTimer = null;

            // LEDs are pulsing
            if (tempData != null) {
                // Pulsing during a disconnection so just redisplay
                showTemperature(tempData);
            } else {
                // Pulsing at start before have received forecast data
                // so just clear the LEDs;
                pixels.fill([0,0,0]).draw();
            }
        } else {
            // Connected and showing a forecast, so clear the display
            down();
        }
    } else {
        // Turn the LEDs back on
        if (tempData == null) {
            // Go back to the start pulse
            startPulse();
        } else {
            if (isDisconnected) {
                disconnectedPulse();
            } else {
                showTemperature(tempData);
            }
        }
    }
});

// ...set debugging
agent.on("set.debug", function(debugValue) {
    // Set or unset the debugging flag as required
    debug = debugValue;
    server.log("Debugging " + (debug ? "on" : "off"));
});

// ...set device orientation
agent.on("set.orientation", function(state) {
    // isTopUp is true when LED is on the left, ie. state is true
    if (isTopUp != state) {
        isTopUp = state;
        if (debug) server.log("LED orientation set to LED on the " + (isTopUp ? "left" : "right"));
        if (tempData != null) showTemperature(tempData);
    }
});

// Pulse the LED if we're not actually connected at this point
if (!disconnectionManager.isConnected && isOn) startPulse();