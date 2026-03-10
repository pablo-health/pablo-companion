# Session Context

## User Prompts

### Prompt 1

is there anything in pablo that would explain why around 3 minutes we start dropping audio samples and have a buffer overflow.  it used to be shorter - until the last couple of fixes we made to AudioCaptureKit.    Is logging the Capture state doing anything.  we periodically i think make api calls i think for the sessions on main screen.   is there anything thread wise we aren't doing right, and please don't tell me we are doing the audio processing on the main thread unless we just have to

### Prompt 2

one more question before we do - why are the audio call backs on the main thread - could we have a background thread that processes them

### Prompt 3

would a separate serial queue be better - as we want audiocapturekit to finish its work

### Prompt 4

are there limits on how many items we can have in our dispatch queue

### Prompt 5

yes

### Prompt 6

do we have an issue on relaunching the app -- Restored auth state for kurtn@lll-solutions.com, token valid
Failed to load today's sessions: Not authenticated. Please sign in.    (if we have a valid token - we should sessions without having to click elsehwere)

### Prompt 7

ok let me ask this question - where are logging capture statte (capturing(duration) - i don't feel it's needed

### Prompt 8

yes please it's poluting the logs

### Prompt 9

we are still fetching sessions after the quick start session - could 6 of those cause us problems even though we should have the threading fixed i think

### Prompt 10

when we insert the new row - intiially it says unknown pateitn - but we are still updating the today view.    ok then why do we get the buffer errors

### Prompt 11

we need the separate files for the audio transcription :-(  it makes it easier downstream

### Prompt 12

i do - let me ask this would we run into problems with too many things pending disk i/o

### Prompt 13

yes let's do it, and remember we need to update the github version - think we are going to be on 1.0.5 now

### Prompt 14

[Request interrupted by user for tool use]

### Prompt 15

any lint errors - check for taht first

### Prompt 16

yes please

### Prompt 17

ok still doesn't work - let's try temporarily not using separate PCM streams

### Prompt 18

its something else - although now we get to around 4:30 instead of 3 mintues.  dumb question why do we only have a 100ms budget

### Prompt 19

what's jitter?

### Prompt 20

why do we have to sleep

### Prompt 21

how much overhead would that check be - it's a simple number comparison right?

### Prompt 22

and could we make the ringbuffer big enough to account for how long io takes

### Prompt 23

so every 100 millesconds we write to the file - could we do it every second

### Prompt 24

would a higher value be better - obviously it's a function of our ring buffer

### Prompt 25

ok so 1 second of audio takes 1 second to write to disk

### Prompt 26

that did it let's commit and push - we are 9 minutes in and no problems

