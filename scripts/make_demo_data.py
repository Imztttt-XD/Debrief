#!/usr/bin/env python3
"""Writes fictional demo data for UI snapshots:  make_demo_data.py <data-dir> <some .m4a>
Never point <data-dir> at the real ~/Library/Application Support/Debrief."""
import json, os, sys, uuid, datetime as dt, shutil
out, audio = sys.argv[1], sys.argv[2]
assert "Application Support/Debrief" not in os.path.abspath(out), "refusing to write into the real data dir"
shutil.rmtree(out, ignore_errors=True); os.makedirs(os.path.join(out, "Reviews")); os.makedirs(os.path.join(out, "Resumes"))
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
iso = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")
U = lambda: str(uuid.uuid4()).upper()
def dump(name, obj): json.dump(obj, open(os.path.join(out, name), "w"), ensure_ascii=False, indent=1)

resume_id = U()
dump("resumes.json", [{"id": resume_id, "name": "后端开发简历 v3", "originalFileName": "resume.pdf", "storedFileName": "x.pdf",
                       "text": "张三 | 计算机科学硕士\n项目：知序即时通信系统（Java、Spring Boot、Kafka、Redis）……" * 3, "importedAt": iso(now)}])
dump("profile.json", {"targetDirection": "后端开发 / 全栈开发"})
apps = []
def app(company, role, status, days, jd=""):
    a = {"id": U(), "company": company, "role": role, "jobDescription": jd, "resumeID": resume_id, "status": status,
         "channel": "内推", "notes": "", "createdAt": iso(now - dt.timedelta(days=days)), "updatedAt": iso(now - dt.timedelta(days=days))}
    apps.append(a); return a
a1 = app("星河示例科技有限公司", "全栈开发工程师（Java / Vue）", "interviewing", 1,
         "岗位职责：\n1. 负责即时通信与支付相关后端服务的设计与开发；\n2. 参与高并发场景下的性能优化。\n任职要求：熟悉 Java、Spring Boot、Kafka、Redis、MySQL。")
a2 = app("云帆示例网络", "后端开发实习生", "awaitingResult", 6)
a3 = app("某某银行金融科技子公司", "Java 开发", "applied", 9)
a4 = app("Northwind Demo Labs", "Backend Engineer Intern", "rejected", 20)
dump("applications.json", apps)
ivs = []
def iv(app, rnd, hours, fmt="online", dur=60):
    i = {"id": U(), "applicationID": app["id"], "round": rnd, "start": iso(now + dt.timedelta(hours=hours)), "durationMinutes": dur,
         "format": fmt, "meetingLink": "https://meeting.example.com/j/123456" if fmt == "online" else "", "location": "深圳市南山区科技园" if fmt == "onsite" else "",
         "notes": "面试官是后端组负责人，可能会深挖红包模块" if rnd == "二面" else "", "reminderMinutes": [60, 10], "createdAt": iso(now)}
    ivs.append(i); return i
i1 = iv(a1, "一面", -2)
iv(a1, "二面", 26)
iv(a2, "HR 面", 50, "phone", 30)
iv(a3, "一面", 75, "onsite", 90)
dump("interviews.json", ivs)
rec_id = U()
dump("recordings.json", [{"id": rec_id, "fileURL": "file://" + os.path.abspath(audio), "startedAt": iso(now - dt.timedelta(hours=2)),
                          "duration": 657, "tracks": ["system", "microphone"], "interviewID": i1["id"]}])
lines = [("interviewer", "你好，先做一个简单的自我介绍吧。"), ("me", "面试官好，我是张三，目前研二，主要做后端开发，做过一个即时通信系统。"),
         ("interviewer", "从你的项目里挑一个详细讲讲，具体做了什么、解决了哪些问题？"),
         ("me", "我讲一下知序即时通信系统。我主要负责消息投递和红包模块，红包用 Redis 预扣库存加 Kafka 异步落库，高峰期大概支撑两千 QPS。"),
         ("interviewer", "你说的红包高并发有多高？怎么测的？"), ("me", "我们用 JMeter 压测，单机大概两千 QPS，主要瓶颈在数据库写入。"),
         ("interviewer", "防重复领取是怎么实现的？"), ("me", "用 Redis 的 SETNX 加用户 ID 做幂等，还有数据库唯一索引兜底。"),
         ("interviewer", "Kafka 消费之后做什么？"), ("me", "消费之后写 MySQL，然后更新用户余额，失败的话会重试三次再进死信队列。")]
t, transcript = 3.0, []
for spk, text in lines:
    d = 4 + len(text) / 6
    transcript.append({"id": U(), "speaker": spk, "start": t, "end": t + d, "text": text}); t += d + 1.5
def crit(a, s, d, corr, good, imp, better):
    return {"accuracy": a, "structure": s, "depth": d, "corrections": [{"id": U(), "claim": c[0], "issue": c[1], "correct": c[2], "disputed": False} for c in corr],
            "strengths": good, "improvements": imp, "betterAnswer": better}
questions = [
    {"id": U(), "question": "请先做一个自我介绍，介绍基本情况和经历。", "category": "behavioral", "resumeItem": None, "start": 3.0,
     "answer": lines[1][1], "answerStart": 8.0, "followUps": [],
     "critique": crit(4, 3, 2, [], ["简洁，直接点出方向"], ["可以用一两句话量化项目成果", "缺少求职动机"], "面试官好，我是张三……我最有代表性的项目是知序即时通信系统，负责消息投递与红包模块，把红包接口峰值吞吐做到约 2000 QPS。")},
    {"id": U(), "question": "从你的项目里挑一个详细讲讲，具体做了什么、解决了哪些问题？", "category": "project", "resumeItem": "知序即时通信系统", "start": 20.0,
     "answer": lines[3][1], "answerStart": 28.0,
     "followUps": [{"id": U(), "question": "你说的红包高并发有多高？怎么测的？", "answer": lines[5][1], "start": 45.0},
                   {"id": U(), "question": "防重复领取是怎么实现的？", "answer": lines[7][1], "start": 60.0},
                   {"id": U(), "question": "Kafka 消费之后做什么？", "answer": lines[9][1], "start": 75.0}],
     "critique": crit(3, 4, 3, [("SETNX 加用户 ID 做幂等", "SETNX 没有设置过期时间，进程崩溃会导致锁永久存在", "使用 SET key value NX EX 30 原子设置过期时间")],
                      ["结构清楚，先讲职责再讲方案", "提到了数据库唯一索引兜底"], ["压测数据缺少环境说明（机器配置、并发数）", "没有说明 Kafka 消费失败时如何保证余额一致"],
                      "我负责知序的红包模块。发红包时用 Redis Lua 脚本原子预扣库存，抢红包请求写入 Kafka 异步落库……")},
]
dump("Reviews/" + rec_id + ".json", {"recordingID": rec_id, "createdAt": iso(now), "updatedAt": iso(now), "transcript": transcript,
     "transcriptModel": "qwen3-asr-flash", "transcriptEdited": False, "questions": questions,
     "summary": {"overall": "整体表现中上。项目讲解结构清楚，但关键数据缺少来源，幂等方案存在明显漏洞，被追问时回答偏短。",
                 "strengths": ["项目介绍条理清楚", "能说出兜底方案"], "improvements": ["量化数据要说明测试条件", "分布式锁细节不扎实", "追问时展开不足"],
                 "actionItems": ["整理红包模块压测报告的关键数据", "复习 Redis 分布式锁的正确写法", "准备 Kafka 消费幂等与重试的完整说明"],
                 "interviewerStyle": "偏重项目细节，喜欢沿着一个点连续追问。"},
     "analysisModel": "deepseek-v4-pro", "myNotes": "", "lastError": None})
print("demo data written to", out)

# Question bank and a mock interview in progress.
def bq(q, cat, item, times, mastery, company="星河示例科技有限公司", fu=(), score=None):
    return {"id": U(), "question": q, "category": cat, "resumeItem": item, "followUps": list(fu), "applicationID": a1["id"],
            "company": company, "role": a1["role"], "source": "interview", "timesAsked": times, "firstAskedAt": iso(now - dt.timedelta(days=9)),
            "lastAskedAt": iso(now - dt.timedelta(days=1)), "mastery": mastery, "myAnswer": "用 Redis 的 SETNX 加用户 ID 做幂等……",
            "betterAnswer": "使用 SET key value NX EX 30 原子加锁，并以数据库唯一索引兜底……", "notes": "", "lastScore": score}
dump("question-bank.json", {"items": [
    bq("红包防重复领取是怎么实现的？", "project", "知序即时通信系统", 3, "review", fu=["锁过期了怎么办？", "为什么不用数据库悲观锁？"], score=3.0),
    bq("从你的项目里挑一个详细讲讲，具体做了什么、解决了哪些问题？", "project", "知序即时通信系统", 2, "review", score=3.3),
    bq("Kafka 如何保证消息不丢失？", "fundamentals", "知序即时通信系统", 2, "mastered", score=4.3),
    bq("请先做一个自我介绍。", "behavioral", None, 4, "mastered", score=4.0),
    bq("为什么想来我们公司？", "hr", None, 1, "new", company="云帆示例网络"),
], "ingestedReviews": [rec_id], "ingestedMocks": []})
os.makedirs(os.path.join(out, "MockInterviews"), exist_ok=True)
mock_id = U()
msgs = [("question", "先讲讲你的知序即时通信系统，红包模块你具体负责什么？", "project", "知序即时通信系统"),
        ("answer", "我负责红包模块，发红包时用 Redis 预扣库存，抢红包的请求写进 Kafka 异步落库。", None, None),
        ("followUp", "高峰期大概多少 QPS？是怎么压测出来的？", None, None),
        ("answer", "单机两千左右，用 JMeter 模拟一万个用户并发抢同一个红包。", None, None),
        ("question", "如果 Kafka 消费失败，用户余额会不会不一致？你们怎么处理？", "project", "知序即时通信系统")]
dump("MockInterviews/" + mock_id + ".json", {"id": mock_id, "applicationID": a1["id"], "focus": "project", "questionCount": 5,
     "createdAt": iso(now - dt.timedelta(minutes=12)), "updatedAt": iso(now), "finished": False, "questions": [], "summary": None, "lastError": None,
     "messages": [{"id": U(), "kind": k, "text": t, "createdAt": iso(now), "category": c, "resumeItem": r} for k, t, c, r in msgs]})
print("bank + mock demo data added")
