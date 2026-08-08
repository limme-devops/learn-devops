# Working with PM, PO, Operations and the Business

How to run these conversations so they end in a decision, and so you come across
as someone who knows what they are doing — because you do, and the only thing
missing is the translation layer.

The goal is **not** to prevent technical questions by being vague. Vagueness
reads as evasion and invites more questions. The goal is to answer in the
listener's own terms so completely that the technical question never needs to be
asked — and to have the technical answer ready in one sentence if it is.

---

## 1. Know what each person is actually worried about

They will ask you technical questions, but that is rarely what they want. Answer
the worry, not the words.

| Role | Their real question | What they fear | Answer in terms of |
|---|---|---|---|
| **Product Manager** | "Will it be ready for the date I promised?" | Being surprised late | Dates, dependencies, confidence level, what would move the date |
| **Product Owner** | "Does this deliver user value, and what's the priority?" | Building the wrong thing | User impact, trade-offs, what we give up |
| **Operations / SRE** | "Who gets paged at 3am, and what do they do?" | Owning something they can't fix | Runbooks, alerts, rollback, support model |
| **Security / Risk** | "What is the residual risk and who accepted it?" | Signing off on something unquantified | Controls, evidence, exceptions with expiry |
| **Compliance / Audit** | "Can you prove that, for the last 12 months?" | Findings in a report | Evidence artifacts, retention, who approved what |
| **Finance** | "What does it cost, and why that much?" | Unbudgeted surprises | Run cost, one-off cost, cost of *not* doing it |
| **Executive** | "Is this on track, and what could go wrong?" | Being blindsided | Status, top three risks, what you need from them |

**The move:** before any meeting, write one sentence — *"The person I'm talking
to is worried about X."* Then open with X.

---

## 2. The translation layer

Use the right-hand column in the room. Keep the left-hand column for engineers.

| What you'd say to an engineer | What you say to the business |
|---|---|
| "We need to set up Vault before the apps" | "Credentials have to be managed centrally before we build on top, or we redo the app work later. Two weeks now saves about eight." |
| "The RPO is 15 minutes" | "If we lose the primary site, we could lose up to 15 minutes of transactions. Is that acceptable, or do we need to invest in getting it lower?" |
| "We're at 80% of the error budget" | "We've used most of this month's allowance for customer-visible failures. I'm recommending we pause non-critical releases for two weeks and fix stability first." |
| "It needs a canary deployment" | "New versions go to 5% of customers first. If anything looks wrong it rolls back automatically, usually before anyone notices." |
| "We need default-deny NetworkPolicies" | "Systems can only talk to what they're explicitly allowed to. If one is compromised, the attacker can't move sideways to the customer database." |
| "That's tech debt" | "That's a shortcut we took to hit a date. It's costing us roughly two days a month, and it will get worse. Here's what fixing it costs." |
| "We need a maintenance window" | "We need 90 minutes on a Sunday to do this safely. Doing it during the week means a small risk of customer impact." |
| "The migration isn't backwards-compatible" | "Once we make this change we can't easily undo it. I want an extra week to do it in reversible stages." |
| "We haven't tested the restore" | "We have backups, but we've never proven we can restore from them. Until we test it, I can't promise a recovery time." |
| "It's an eventually-consistent read" | "The balance shown might be a second or two behind. That's fine for a dashboard; it is not fine for an authorisation decision." |

**Rule:** every technical term you use costs you credibility with a non-technical
audience unless you immediately show why it matters to *them*. If you cannot say
why it matters to them, it does not belong in that meeting.

---

## 3. The three-layer answer

Use this for every question. It makes you sound confident, controlled, and
prepared, and it lets the listener choose the depth.

```
Layer 1 — the headline      (one sentence, plain language, the answer)
Layer 2 — the consequence   (what it means for them, with a number)
Layer 3 — the detail        (offered, not delivered: "happy to go deeper")
```

**Example — "Why can't we deploy on Friday?"**

> **L1:** We can, but I'd recommend against it.
> **L2:** If a problem appears slowly it usually shows up six to eight hours
> after release. On a Friday that's midnight, with a skeleton team, and a
> fix takes about three times longer.
> **L3:** I can walk you through last quarter's incident timings if useful.

**Example — "Why does this take six weeks?"**

> **L1:** Four weeks of build and two weeks of proving it works.
> **L2:** The two weeks are backup restores and failure testing. That's what
> lets me tell you a recovery time with confidence rather than a guess.
> **L3:** I've got the week-by-week breakdown if you want to look for anything
> to cut.

Notice that Layer 3 is always an *offer*. Volunteering detail nobody asked for
is the single most common way engineers lose a room.

---

## 4. Question bank — prepare these answers before the meeting

These are the questions that actually get asked. Having a crisp answer ready is
most of what "confident" means.

### From the PM

**"Can we go live earlier if we skip the security review?"**
> No, and I want to be clear why: in a regulated environment an unreviewed
> release is a reportable finding, which costs more time than the review. What I
> can do is start the review in parallel from next week instead of at the end —
> that gets us about five days back. Shall I set that up?

*(Say no once, give the reason once, then immediately offer the thing you can
do. Never say no without a path.)*

**"Why is your estimate a range and not a date?"**
> Because I'd rather give you a number you can plan against than one that sounds
> precise and moves. It's four to six weeks, and I'm about 80% confident of six.
> The variable is firewall approvals — if those land in week two, it's four.

**"The other team said this would take two days."**
> Two days is right for the change itself. My estimate includes testing the
> rollback and updating the runbook, which is about three more days. I can drop
> those, but then we're accepting that if it goes wrong in production we're
> improvising. That's your call — I just want it to be a decision rather than an
> accident.

**"Can you give me a percentage complete?"**
> Eight of the twelve steps are done and verified. The remaining four are the
> testing ones, which is roughly 30% of the effort. I'd say we're two weeks out
> with the risks I flagged last week unchanged.

*(Never say "90% done". Report completed, verified units of work.)*

### From the PO

**"Which of these should we do first?"**
> If we do A first, users get the new flow two weeks earlier but we carry a
> manual reconciliation step until B lands. If we do B first, nothing is visible
> to users for three weeks but there's no manual work afterwards. My recommendation
> is B, because the manual step is where mistakes happen with money. Your call.

*(Always: option, consequence, recommendation, hand back the decision.)*

**"Can we release it to everyone at once?"**
> We can, and it's slightly faster. Going to 5% first costs us about two hours
> and means that if something's wrong, fifty customers see it instead of ten
> thousand. I'd take the two hours.

**"Why do we need a feature flag if we've tested it?"**
> Testing tells us it works the way we expect. The flag is for the way we didn't
> expect. It means turning it off is a five-second config change instead of a
> forty-minute redeploy.

### From Operations

**"What will page us, and how often?"**
> Six alerts page. Based on the last quarter's data I'd expect about one page a
> month, mostly database connection saturation. Every one links to a runbook with
> the first three commands to run. I'd like to walk your team through them before
> we go live, and I'll be on the rotation myself for the first month.

*(Offering to carry the pager for the first month buys more trust than any
document.)*

**"What if we can't fix it?"**
> Escalation is you → me → platform lead → CTO, with contact details in the
> runbook. And every runbook's first option is the rollback, so the default
> action is always "put it back how it was", not "debug it at 3am".

**"How do we know it's working?"**
> There's a dashboard link in every alert, and a one-page health view showing the
> four things that matter. If those are green, it's working. If you're ever
> unsure, roll back — I would rather you roll back unnecessarily than hesitate.

**"You're giving us something new to look after. What are you taking away?"**
> Fair question. This replaces the manual deployment checklist and the weekly
> config drift check — roughly six hours a month. Net it should be less work, and
> I'll track that with you after a month.

*(Ops is often handed work with nothing removed. Acknowledging that earns
enormous goodwill.)*

### From Security and Compliance

**"How do you know nobody can access production directly?"**
> Standing access is zero — that's enforced, not policy. Access requires an
> incident ticket and a second approver, it's time-boxed to two hours, the session
> is recorded, and granting it fires an alert to your team. I can show you the
> access log for the last 90 days now if you'd like.

**"What happens if an engineer leaves?"**
> One action in the directory. They lose every console, the cluster, Vault and the
> repos, because everything authenticates through the same identity. No
> per-system offboarding checklist to get wrong.

**"Show me the evidence."**
> It's generated automatically — approvals, scan results, exception register,
> restore-drill records. I can produce a dated pack for any period in about ten
> minutes rather than three weeks. Which period do you want?

### From Finance

**"Why does this cost so much?"**
> The single biggest line is the second site for disaster recovery. If we drop it,
> we save roughly 30%, and our recovery time goes from 15 minutes to about two
> days. That's a business decision about acceptable downtime, not a technical one
> — I can put both options in writing.

**"Can we use cheaper hardware for the non-production environments?"**
> Yes for dev, no for UAT. UAT has to behave like production or it stops being a
> useful test, and then we find the problems in production instead. Dev can be
> half the size and I'd estimate that saves about 15%.

### The hardest one: "Just make it work, we'll fix it later"

> I can do that, and I want to make sure we're both clear on what we're choosing.
> Skipping the restore test means that if we lose the database, I can't tell you
> how long recovery takes — it might be an hour, it might be a day. If you're
> comfortable with that for the next six weeks, I'll note it as an accepted risk
> with your name on it and we'll schedule the test for the first week of Q3. Is
> that the trade you want to make?

*(This is the most useful sentence in this document. You do not refuse. You make
the risk specific, attach a name and a date to it, and let them decide. Nine
times out of ten the answer becomes "no, let's do it properly." The tenth time,
you have it in writing.)*

---

## 5. Meeting procedures

### 5.1 Before any meeting (15 minutes, always worth it)

1. Write the **one decision** you need out of this meeting. If there isn't one,
   consider whether it should be an email.
2. Write the **one sentence** of what your audience is worried about.
3. Prepare **three numbers**. Vague statements invite interrogation; numbers end
   it. "About 40% faster" beats "significantly faster" every time.
4. Prepare your **recommendation**, not just options. People asked to choose
   between options with no recommendation will defer the decision.
5. Send a **pre-read** the day before: half a page, the decision needed, the
   options, your recommendation. This alone eliminates most derailing questions,
   because people arrive already oriented.

### 5.2 During

**Open with the conclusion.** Not the journey.

> "I'm recommending we push the go-live by one week. Here's why, and here's what
> we get for it."

Everything after that sentence is supporting detail people can opt into. Leading
with background and building to a conclusion is how engineers lose rooms —
halfway through, someone interrupts with a question you were going to answer in
two minutes, and control of the meeting goes with it.

**Time-box your own answers.** Roughly 30 seconds, then stop and check: "Does
that answer it, or do you want more detail?" Silence after a complete answer
reads as confidence. Continuing to talk reads as uncertainty.

**Write decisions down live.** "So the decision is: we go with option B, and
Sarah is confirming the budget by Thursday. I'll send that round after the call."
Nobody argues with a decision log written in the room. Everybody argues with one
written three days later.

**Do not defend, redirect.** If someone challenges a technical choice they don't
understand, don't defend the technology — redirect to the outcome:

> "The specific tool matters less than the outcome, which is that a bad release
> rolls back on its own in under a minute. If there's a different way to get
> there I'm genuinely open to it."

### 5.3 After (within 24 hours)

Send a short note:

```
Decisions
  1. Go-live moves to 14 March. (Agreed: PM, PO)
  2. DR site approved in principle, budget confirmation by 6 March. (Owner: Finance)

Actions
  - [Platform] Firewall requests raised by 28 Feb
  - [Ops] Runbook walkthrough scheduled week of 3 March
  - [PM] Communicate the new date to the business

Risks unchanged
  - Firewall approval lead time (highest risk to the date)

Assumptions I'm proceeding on
  - RPO of 15 minutes is acceptable. Please correct me this week if not.
```

That last section is the most valuable habit in this document. **Assumptions
stated in writing become decisions.** Assumptions left unstated become arguments
in the post-incident review.

---

## 6. Estimating without losing credibility

| Do | Don't |
|---|---|
| Give a range with a confidence level | Give a single date to sound decisive |
| Say what would make it faster or slower | Pad silently and hope |
| Break work into verified units and report those | Report "percent complete" |
| Re-forecast as soon as you know, not at the deadline | Hope it recovers |
| Separate "build" from "prove it works" | Bundle them and get the testing cut |

**The formula that works:**

> "Four to six weeks. I'm confident of six. The variable is X. If X lands by
> week two, it's four. I'll tell you which by the 15th."

You have given a plannable number, named the risk, and committed to a checkpoint.
That is what "reliable" sounds like.

**Re-forecast early and without drama.** A slip reported in week two is a
planning input. The same slip reported in week five is a crisis, and the damage
to your credibility comes from the timing, not the slip.

---

## 7. How to say the hard things

### Saying "I don't know"

The confident version has three parts: admit it, say how you'll find out, commit
to a time.

> "I don't know — I don't want to guess at something this important. I can have
> a firm answer by Thursday afternoon. Does that work?"

This *increases* trust. Guessing and being wrong once destroys it for a year.
What kills credibility is not "I don't know", it is "I don't know" with no plan
attached.

### Delivering bad news

Lead with it. Then impact, then plan, then what you need.

> "The restore test failed — we couldn't recover the database within our target.
> No customer impact, nothing is at risk right now, but our stated recovery time
> isn't real yet.
> I've found the cause and I need a week to fix and re-test.
> What I need from you is a decision on whether we go live before that's proven,
> and my recommendation is that we don't."

Never bury bad news in a status report. Never let someone else discover it.

### Pushing back

Use their own agreed numbers rather than your opinion. Opinions are arguable;
agreed numbers are not.

> "We agreed a 99.9% availability target, which is 43 minutes a month. We've used
> 38 of those in three weeks. Shipping this change now most likely means we breach
> the target we committed to. I'd rather spend next week on stability and ship
> this the week after. If the date matters more, that's a legitimate call — I just
> want it made deliberately."

This is why SLOs and RTOs are worth the effort to agree up front. They convert
"the engineer is being cautious" into "we are outside the parameters we all
agreed", which is a much easier conversation.

### Admitting a mistake

> "That was my error — I misread the retention setting and we lost four days of
> non-critical logs. Nothing customer-facing. I've fixed the setting, added a
> check so it can't happen silently again, and the details are in the postmortem."

Own it, state the blast radius precisely, say what prevents a recurrence, move
on. Do not over-apologise; it makes people wonder if it was worse than you said.

---

## 8. Words to drop, and what to use instead

| Instead of | Say |
|---|---|
| "It should work" | "It's tested, and here's how we'd know if it wasn't" |
| "That's not my area" | "That's owned by X — I'll connect you and follow up" |
| "It's complicated" | "There are three moving parts. The one that matters to you is…" |
| "Obviously" / "Just" / "Simply" | (delete — these make people feel stupid and stop asking) |
| "We can't" | "We can, and here's the cost" or "Not by that date; here's what we can do" |
| "It's basically done" | "The build is done. Testing and the runbook are outstanding — three days." |
| "The system went down" | "Customers couldn't make payments for eleven minutes" |
| "Tech debt" | "A shortcut we took, costing about two days a month" |
| "I think" / "maybe" / "probably" (when you know) | State it. Reserve hedging for genuine uncertainty. |
| "As I said before…" | Just answer it again, differently. |

**On hedging:** using "I think" when you actually know makes everything else you
say sound uncertain too. Save it for real uncertainty, and then it carries
information.

---

## 9. What actually makes you credible

Not vocabulary. Not diagrams. These, in order:

1. **You said a date and it happened.** Nothing else comes close. Under-promise
   slightly, hit it, repeat. Three of these and you get the benefit of the doubt
   for a year.
2. **You raised the bad news first.** People forgive problems. They do not
   forgive finding out from someone else.
3. **You quantify.** "About 40% faster, from 12 minutes to 7" ends the discussion.
   "Much faster" starts one.
4. **You gave a recommendation.** Presenting three options with no view reads as
   avoiding responsibility.
5. **You said "I don't know" once and then came back with the answer on time.**
6. **You made the risk someone else's decision, in writing, without being
   passive-aggressive about it.**
7. **You knew what it cost.** Engineers who can talk about money get listened to
   by people who control it.

---

## 10. Pocket cards

### Before you walk in
```
Decision needed:      ______________________
They're worried about: ______________________
My three numbers:     ______________________
My recommendation:    ______________________
```

### When put on the spot
```
1. Headline in one sentence
2. What it means for them, with a number
3. "Happy to go deeper if useful"
4. Stop talking
```

### When asked to cut a corner
```
1. "I can do that."
2. Name the specific risk, concretely
3. Attach a name and a date to accepting it
4. Give your recommendation
5. Hand the decision back
```

### When you don't know
```
1. "I don't know."
2. "I'll find out by <specific time>."
3. Do it, and be early.
```

### Weekly status, in four lines
```
Done:      what is finished AND verified
Next:      what happens this week
Risks:     top 1-3, with the mitigation
Need:      the decision or unblock you want from them
```

---

## 11. A worked example

**Situation.** Six days before go-live, the restore test fails. The PM has
already announced the date externally.

**Wrong version** (waits for the status meeting, opens with detail):
> "So we were running the PITR drill and the WAL archive had a gap because the
> retention lifecycle policy on the object store was misconfigured, which means
> Barman couldn't replay past the checkpoint, and…"

The PM has stopped listening at "PITR", is now anxious without knowing why, and
will ask a defensive question. You have lost the room and you were not even
wrong.

**Right version** (same day, phone call, then written):

> "I need five minutes — something came up that affects the date.
>
> Our database recovery test failed today. Nothing is broken and no customer is
> affected. What it means is that if we lost the database after go-live, I
> couldn't tell you whether recovery takes one hour or one day.
>
> I know the cause and I need six days to fix it and re-test. That puts us one
> week past the announced date.
>
> Two options. We go live on the date and accept that recovery time is unknown
> for a week — I'd want that recorded as an accepted risk. Or we move by a week
> and go live with a proven recovery time.
>
> I recommend moving. This is a payments system, and 'we don't know how long
> recovery takes' is not something I want us to discover during an incident.
>
> Whichever you choose, I'll have it in writing this afternoon and I'll help
> with the comms if we're moving."

Every element that matters is there: early, headline first, blast radius stated
precisely, cause understood, options, a clear recommendation with a reason a
non-engineer can evaluate, and an offer to help with the consequences.

You have not been difficult, defensive, or vague. You have been the person they
want in the room next time.
