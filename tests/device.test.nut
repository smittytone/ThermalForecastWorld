class TFWTestCase extends ImpTestCase {

    function testShowTemperature() {

        local ts = "30.0:20.0:10.0:0.0:-10.0";
        this.showTemperature(ts);

        imp.wakeup(10, function() {
            assertEqual(this.ts, this.tempData);
        }.bindenv(this));
    }
}