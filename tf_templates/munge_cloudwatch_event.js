const os = require('os');

const events = require('./cloudwatch_event_rule_patterns.json');

const tempDir = `${os.tmpdir()}/terraform-ecs/event_${new Date().getTime()}`;

const event = {
    ...events[0],
    DetailType: events[0].DetailType[0],
    Detail: JSON.stringify({
        test: 1
    })
};

console.log(JSON.stringify(event));