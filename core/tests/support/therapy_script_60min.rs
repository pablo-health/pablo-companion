// therapy_script_60min.rs — Full 60-minute CBT session for work anxiety.
//
// Realistic cognitive behavioral therapy session between Dr. Sarah Chen
// and her client Alex Rivera. Covers: check-in, exploring anxiety triggers,
// cognitive distortions, physical symptoms, coping strategies, cognitive
// restructuring, behavioral experiments, and session wrap-up.

#[derive(Clone, Copy, PartialEq)]
pub enum Speaker {
    Therapist,
    Client,
}

pub struct ScriptLine {
    pub speaker: Speaker,
    pub text: &'static str,
}

pub const SCRIPT: &[ScriptLine] = &[
    // ── Phase 1: Opening & Check-in ──────────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Good afternoon Alex. Come on in, have a seat. How are you doing today?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Hi Doctor Chen. I'm okay I guess. A little anxious actually, which is kind of why I'm here. It's been a really rough couple of weeks at work.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "I'm glad you came in. Before we dive into what's been happening, let me check in on where things stood after our last session. You mentioned you were going to try the deep breathing exercises when you felt the anxiety coming on. How did that go?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Yeah, I did try them a few times. Honestly, they helped in the moment, like when I was sitting at my desk and could feel my heart starting to race. But then something would happen and all the anxiety would come flooding back. It felt like I was putting a bandaid on a broken arm, you know?",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "That's a really helpful observation actually. The breathing exercises are meant to manage the physical symptoms in the moment, but you're right that they don't address the underlying thoughts driving the anxiety. That's exactly what I want us to work on today. Can you tell me what's been happening at work?",
    },

    // ── Phase 2: Exploring the Situation ─────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Client,
        text: "So about three weeks ago, my manager called an all-hands meeting. She announced that the company is restructuring and there will be layoffs in the next quarter. She didn't say how many people or which departments, just that it was coming. Ever since then I've been a complete mess.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "That sounds like a really stressful situation, and it makes complete sense that you'd feel anxious about it. The uncertainty must be particularly difficult. What has your day to day been like since the announcement?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "It's been terrible honestly. I wake up every morning with this pit in my stomach. I get to work and I can barely concentrate. I'm constantly watching for signs, like if my manager seems distant, or if I see people having closed door meetings. Last week I saw two people from HR walking through our floor and I nearly had a panic attack.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "You mentioned you're watching for signs and interpreting things around you. When you saw the HR people walking through your floor, what went through your mind in that moment?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "My first thought was, this is it, they're coming to let people go. I felt my heart start pounding and my hands got sweaty. I actually got up and went to the bathroom because I thought I might be sick. I sat in there for about ten minutes trying to calm down.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "I appreciate you sharing that. It sounds like a really intense physical and emotional reaction. Let me ask you this: after those ten minutes, what actually happened with the HR people?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Nothing. I came back to my desk and everything was normal. My coworker said they were just doing some kind of facilities walkthrough. It had nothing to do with layoffs at all. But even after I found that out, I still felt on edge for the rest of the day.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "That's a really important example and I want us to come back to it. You had a thought, this is it they're coming to let people go, which triggered an intense physical response. But the reality turned out to be completely different. Does this kind of pattern happen often?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "All the time now. Every time my manager sends a calendar invite for a one on one, I assume it's bad news. When my coworkers are whispering, I think they know something I don't. Even when I get a Slack message from someone I don't usually talk to, my first thought is that something is wrong.",
    },

    // ── Phase 3: Cognitive Distortions ────────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Therapist,
        text: "What you're describing is something we call catastrophizing, or jumping to the worst case scenario. Your brain is in threat detection mode, and it's interpreting neutral or ambiguous signals as dangerous. This is actually a very common response to uncertainty. Have you noticed any patterns in the specific thoughts you're having?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "I think the biggest one is that I'm going to be the first person let go. Like, I've convinced myself that I'm the weakest link on the team. I keep thinking about every mistake I've made over the past year, every project that didn't go perfectly, and I'm sure my manager has a list.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Let's examine that thought for a moment. You said you've convinced yourself you're the weakest link. What evidence do you have for that belief?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Well, there was that project last September where we missed the deadline. I was the lead on that. And I had a bug in production in November that caused some downtime. Plus I was the last person hired on the team, so if they go by seniority, I'm first out the door.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Okay, so you've identified some specific things. Now I want to ask the flip side. What evidence is there against the belief that you're the weakest link? Think about your performance reviews, feedback from colleagues, any wins you've had.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "I mean, my last performance review was actually pretty good. My manager gave me a meets expectations with some exceeds in a couple areas. And I did lead that infrastructure migration in January that went really smoothly. Several people complimented me on it. But those things feel less important somehow.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "That's interesting, isn't it? Your positive evidence is actually quite strong. A good performance review, a successful migration, compliments from colleagues. But you said those things feel less important. Why do you think the negative experiences carry more weight in your mind?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "I don't know. I guess when I'm anxious, the bad stuff is all I can see. It's like the good things happened to a different person and the mistakes are the real me. That sounds crazy when I say it out loud.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "It doesn't sound crazy at all. What you're describing is called a negative mental filter. When we're anxious, our brain literally filters out positive information and amplifies negative information. It's not a character flaw, it's just how anxiety works. The good news is that once we recognize the pattern, we can start to challenge it.",
    },

    // ── Phase 4: Impact on Life ──────────────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Client,
        text: "It's not just at work either. It's affecting everything. My girlfriend has been really patient but I can tell she's getting frustrated. Last weekend she wanted to go out to dinner and I said no because I was too anxious to eat. We ended up having a fight about it.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "I'm sorry to hear that. How did the conversation go with your girlfriend?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "She said she feels like she's losing me to this anxiety. That I'm not present even when I'm physically there. She's right, honestly. I'm always on my phone checking work emails or Slack, even on weekends, just looking for any signal about the layoffs. I know it's not healthy but I can't stop.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "It sounds like the anxiety has expanded beyond work hours and is affecting your relationship and your quality of life. The constant checking behavior you described, that's actually a form of reassurance seeking. You're looking for information to reduce the uncertainty, but it usually has the opposite effect. Does the checking actually make you feel better?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "No, not really. Sometimes I'll see a normal message and feel relieved for about five minutes. But then I start thinking, well maybe they just haven't sent the bad news yet. So I keep checking. It's exhausting. I've been averaging maybe four or five hours of sleep a night.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Four to five hours is significantly less than what your body needs. The sleep deprivation is probably making the anxiety worse too, creating a vicious cycle. Let me ask about other physical symptoms. Besides the sleep, what else have you noticed in your body?",
    },

    // ── Phase 5: Physical Symptoms ───────────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Client,
        text: "The biggest thing is the tension. My shoulders are constantly up by my ears. I've been getting headaches almost every day, usually by mid afternoon. And my appetite is way down. I've probably lost about eight pounds in the last three weeks without trying.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Those are all classic physical manifestations of chronic anxiety. Your body has been in fight or flight mode for three weeks straight. That's not sustainable, and it's going to affect your cognitive function at work too, which ironically makes the thing you're worried about more likely. Have you considered talking to your primary care doctor about what you're experiencing?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "I haven't. I keep thinking if I can just get through the next few weeks and find out whether I still have a job, everything will go back to normal. I don't want to make it into a bigger deal than it is.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "I understand that perspective, but I'd gently push back on the idea that this isn't a big deal. You're experiencing significant physical symptoms, sleep disruption, appetite loss, relationship strain, and difficulty functioning at work. Those things deserve attention regardless of what happens with the layoffs. Would you be open to at least scheduling a checkup?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Yeah, you're probably right. I'll call them this week. I guess I've been so focused on the work situation that I haven't been taking care of myself in other ways too. I stopped going to the gym about two weeks ago because I felt like I didn't have the energy.",
    },

    // ── Phase 6: Cognitive Restructuring ─────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Let's go back to the core worry and do some structured work on it. The main thought seems to be: I'm going to lose my job. On a scale of zero to one hundred, how strongly do you believe that right now?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Right now, sitting here, maybe seventy five percent. When I'm at work it feels like ninety five percent. It's weird because I know logically that I don't have any actual information about who's being laid off, but the feeling is so strong.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Seventy five percent is a strong conviction. Let's try something. I want you to imagine you're a lawyer and your job is to argue the case that you will not be laid off. What evidence would you present?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Okay, let me think. My performance review was solid. I have specialized knowledge in our infrastructure that nobody else on the team has. I'm the one who built our deployment pipeline and I'm the only person who fully understands it. My salary is probably in the middle range for the team, so I'm not the most expensive person to keep. And my manager has continued to assign me important projects since the announcement, which she probably wouldn't do if she was planning to let me go.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "That's actually a very compelling case. Now, having presented that evidence, what would you say the probability is? Not the feeling, but based on the actual evidence you just laid out.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Based on the evidence, maybe thirty or thirty five percent? I mean, there is a real possibility, I'm not going to pretend there isn't. But it's definitely not the ninety five percent certainty that my anxiety is telling me it is.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Exactly. Going from ninety five percent to thirty five percent is a huge shift, and notice that it didn't require you to lie to yourself or pretend everything is fine. It just required looking at all the evidence instead of only the evidence that supports the fear. This is what we call balanced thinking.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "That does feel different. Thirty five percent is still scary, but it feels manageable. At ninety five percent I feel helpless. At thirty five percent I feel like there's something I can do.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "That's a really important insight. Let's build on that. Even if we accept that there's a thirty five percent chance of being laid off, let's look at what that would actually mean. What's the worst case scenario if you did lose this job?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Well, the absolute worst case is that I don't find another job and I run out of money. But realistically, I'm a software engineer with five years of experience. The job market isn't great right now, but it's not terrible for people with my skills. I have about four months of savings, and I'd probably get some severance.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "So even in the scenario where you do lose your job, you have a safety net. Four months of savings plus severance, and marketable skills. How does it feel to think about it that way?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Honestly, a lot less terrifying. I think what's been happening is I jump straight from the announcement to I'm going to be homeless without thinking about any of the steps in between. When I actually lay out the realistic scenario, it's not great, but it's survivable.",
    },

    // ── Phase 7: Coping Strategies ───────────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Therapist,
        text: "You're doing great work here Alex. Now I want to talk about some practical strategies for managing the anxiety between now and whenever the company makes its decisions. First, let's talk about the checking behavior. What would you think about setting specific times to check work messages outside of work hours, instead of checking constantly?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Like a schedule? I could probably do that. Maybe once in the evening, like at seven PM, and then put the phone away. The problem is that I'll be anxious about what I might be missing.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Yes, you will feel anxious at first. That's expected. But what usually happens is that the anxiety peaks and then naturally decreases on its own, even without checking. This is called habituation. Each time you resist the urge to check and nothing bad happens, your brain learns that it doesn't need to be on high alert. Would you be willing to try it as an experiment this week?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "An experiment. I like that framing. It feels less permanent than saying I'm never going to check my phone again. Yeah, I can try it for a week and see what happens. What if something actually important does come through?",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "If something truly urgent happens at work, they will call you. That's what phone calls are for. In your entire career, how many times has something work-related been so urgent that it couldn't wait until the next morning?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Maybe twice? And both times someone actually called me. Yeah, okay. I see your point. The stuff I'm obsessively checking for is not time sensitive. Whether I find out about a layoff decision at eight PM or eight AM doesn't actually change anything.",
    },

    // ── Phase 8: Behavioral Experiments ──────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Exactly. Now let's talk about another strategy. You mentioned you stopped going to the gym. Exercise is actually one of the most effective anxiety reducers we have. It burns off the stress hormones that are keeping your body in fight or flight mode. What would it take to get back to the gym this week?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "I think the barrier is that I feel like I should be using that time to prepare for a potential job search. Like, I should be updating my resume or practicing for interviews. Going to the gym feels irresponsible when my career might be on the line.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Let me challenge that. If you're sleep deprived, physically tense, and cognitively impaired from anxiety, how effective do you think your job search preparation would actually be?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Probably not very effective. Last night I tried to update my resume and I just stared at the screen for forty five minutes. I couldn't think of how to describe anything I've done. My brain felt like mush.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "So the anxiety is actually making you less prepared, not more prepared. Taking care of your physical and mental health is preparation. Going to the gym, getting adequate sleep, eating properly, these things will make you sharper and more effective whether you stay at your current job or need to look for a new one.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "I never thought about it that way. I've been treating self care like a luxury when it's actually part of the strategy. Okay, I'll commit to going to the gym at least three times this week. Even if it's just for thirty minutes.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Three times is great. And I want you to notice how you feel before and after each gym session. Just a quick mental check-in. Rate your anxiety on a scale of one to ten before you go and after you come back. You might be surprised at the difference.",
    },

    // ── Phase 9: Sleep Hygiene ───────────────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Client,
        text: "What about the sleep though? That's the one that feels hardest to fix. I lie in bed and my mind just races. I go through every possible scenario over and over. Sometimes I don't fall asleep until two or three in the morning and then my alarm goes off at six thirty.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "The racing thoughts at night are very common with anxiety. A few things that can help. First, set a worry window earlier in the evening, maybe right after dinner. Give yourself fifteen minutes to write down all your worries. Get them out of your head and onto paper. Then when they come up at bedtime, you can tell yourself, I've already dealt with this, it's on my list, I'll handle it tomorrow.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "A worry window. That's an interesting idea. So I'm not suppressing the worry, I'm just scheduling it?",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Exactly. Trying to suppress anxious thoughts actually makes them stronger. It's the classic don't think about a pink elephant problem. Instead, you're giving them their designated time and place. The other thing I'd recommend is getting screens out of the bedroom. No phone by the bed. Use a regular alarm clock. The blue light disrupts your melatonin production, and having your phone right there makes it too easy to start checking work messages when you can't sleep.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "That's going to be tough. My phone is basically my security blanket at this point. But I know you're right. My girlfriend has been saying the same thing for weeks. Maybe if I put it in the living room and charge it there overnight.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "That's a perfect solution. Out of reach, still available if someone calls in an actual emergency, but not right there tempting you at two AM.",
    },

    // ── Phase 10: Workplace Strategies ───────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Client,
        text: "Can we talk about what I should actually do at work? Like, should I talk to my manager about the layoffs? Should I start job searching now? I feel paralyzed because I don't know what the right move is.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Those are practical questions, and I think it's helpful to separate what's in your control from what isn't. You can't control whether there are layoffs or who gets selected. But you can control your own actions and how you show up at work. What do you think would happen if you talked to your manager about how you're feeling?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Honestly, I'm afraid it would make me look weak or like I can't handle pressure. In our industry, you're supposed to be tough and adaptable. Admitting that I'm having anxiety feels like painting a target on my back.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "I hear that concern. You don't need to share everything you're feeling. But there might be a way to have a productive conversation. For example, you could ask your manager for feedback on your performance and ask what you can do to add the most value to the team during this transition. That gives you information without making you vulnerable.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Oh, that's smart. It's actually just good professional practice, not a sign of weakness. And the feedback would give me real data instead of all these stories I'm making up in my head. I could probably ask her next week during our regular one on one.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "I think that's a great plan. And as for job searching, there's nothing wrong with quietly exploring your options. It can actually reduce anxiety because it gives you a sense of agency. You're not just waiting passively for something to happen to you. You're taking action. But I'd frame it as exploring, not desperately searching. There's a difference in energy.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "That makes sense. I've been thinking about it as this panicked emergency thing, but if I just casually look at what's out there and maybe update my LinkedIn, it feels more like a normal career activity. Less desperate.",
    },

    // ── Phase 11: Relationship ───────────────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Therapist,
        text: "I want to circle back to your relationship for a moment. You mentioned your girlfriend feels like she's losing you to the anxiety. Have you been able to talk to her about what you're going through, not just the work situation, but how it's affecting you emotionally?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Sort of. I've told her I'm stressed about work, but I don't think I've really let her in on how bad it is. Part of me doesn't want to burden her, and part of me is embarrassed. I'm supposed to be the stable one in the relationship. We're talking about moving in together and I feel like admitting how much I'm struggling would make her question that.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "What makes you think that vulnerability would push her away? From what you've told me, she's been patient and trying to connect with you. It sounds like the distance is what's causing the strain, not your feelings.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "You know what, that's true. She's not frustrated because I'm anxious. She's frustrated because I'm shutting her out. When I think about it, the times when we've been closest were when one of us was going through something hard and we supported each other. Like when her mom was sick last year, she leaned on me and it actually brought us closer.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "It sounds like you already know that openness strengthens your relationship. What would it look like to let her in on what you're experiencing? You don't have to have it all figured out. You can just say, I'm having a really hard time with this and I wanted you to know.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "I think I can do that. Maybe tonight. I'll tell her that I've been struggling more than I've let on, and that I'm working on it in therapy, and that I want her support but I also want to be better about being present when I'm with her. She deserves that.",
    },

    // ── Phase 12: Summary and Action Plan ────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Therapist,
        text: "We've covered a lot of ground today Alex. Let me summarize what we've talked about and the strategies we've identified. First, we looked at the catastrophizing pattern, how your brain jumps to worst case scenarios and filters out positive evidence. We did the evidence exercise and brought your belief from ninety five percent down to about thirty five percent.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Right. And even at thirty five percent, looking at the realistic worst case scenario made it feel a lot more manageable.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Exactly. Second, we identified several practical strategies. Limiting phone checking to once in the evening. Getting back to the gym three times this week, noting your anxiety before and after. The worry window technique for managing nighttime racing thoughts. Moving your phone out of the bedroom. Having a feedback conversation with your manager. And opening up to your girlfriend about what you're going through.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "That's a lot when you list it all out. I'm worried I won't be able to do everything.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "You don't have to do everything perfectly. If I had to pick the top three that would make the biggest difference, I'd say: the phone checking limit, getting back to the gym, and talking to your girlfriend. Start with those and see how they feel. Everything else is a bonus.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Okay. Phone checking limit, gym three times, talk to my girlfriend. I can handle three things. And honestly I already feel a little better just having talked through all of this. Putting words to what's been happening in my head makes it feel less overwhelming.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "That's the power of externalizing your thoughts. When they're bouncing around inside your head, they feel enormous and chaotic. When you say them out loud or write them down, they become specific problems that can be addressed. I'd also like you to schedule that doctor's appointment we discussed.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "I will. I'll call them tomorrow morning. You know, when I came in here today I felt like I was drowning. I still have the same problems, nothing has actually changed with the work situation. But I feel like I can breathe again. Like I have a plan instead of just spinning.",
    },

    // ── Phase 13: Closing ────────────────────────────────────────────────────

    ScriptLine {
        speaker: Speaker::Therapist,
        text: "That shift from helplessness to agency is really important. The situation hasn't changed, but your relationship to it has. One more thing: I want you to practice the evidence technique on your own this week. When you catch yourself catastrophizing, pause and ask yourself, what's the evidence for this thought, and what's the evidence against it? You can even write it down.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Like a two column thing? Evidence for, evidence against?",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Exactly. It's called a thought record. And don't judge the thoughts, just examine them. The goal isn't to talk yourself out of being anxious. It's to make sure your thinking is based on reality rather than fear. We'll review how it went next week.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Got it. Two columns, evidence for and against. I'll try to do it at least once a day, maybe during that worry window time you suggested. That way I'm not just worrying, I'm actually doing something constructive with it.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "That's a brilliant idea, combining the worry window with the thought record. Same time next week?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Same time works great. Thank you Doctor Chen. I really appreciate your help with all of this. I feel like I actually have tools now instead of just white knuckling it.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "You're doing the hard work Alex. I'm just helping you see what's already there. Take care of yourself this week, and remember, the anxiety is going to try to convince you that everything is urgent. It's not. You have time. I'll see you next week.",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Thanks. I'll see you next week. Have a good evening.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "You too Alex. Take care.",
    },
];
