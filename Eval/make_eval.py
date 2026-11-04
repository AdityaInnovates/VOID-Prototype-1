import json
C=[]
def add(slice_,pairs):
    for p in pairs:
        text,expect=p[0],p[1]
        args=p[2] if len(p)>2 else None
        C.append((slice_,text,expect,args))

add("music_en",[
("pause","music:pause"),("pause the music","music:pause"),("stop the music","music:pause"),
("resume","music:resume"),("continue playing","music:resume"),
("next song","music:next"),("skip","music:next"),("skip this song","music:next"),
("play the previous song","music:previous"),("go back a song","music:previous"),
("play that again","music:replay|music:previous"),
("volume up","music:volume"),("turn the volume down","music:volume"),("set volume to 40 percent","music:volume"),
("what's playing","music:nowPlaying"),("who sings this","music:nowPlaying"),
("i like this song","music:like"),("i don't like this song","music:dislike"),
("play my liked songs","music:likedSongs"),("play the playlist soft sad raps","music:playlist"),
("play laal pari","music:song"),("play choot vol 1","music:song"),("play shape of you by ed sheeran","music:song"),
("play something calm","music:suggest"),("play something random","music:random|music:suggest"),
("play a random chill song","music:random"),("play some punjabi songs","music:suggest|music:song"),
("play something for the gym","music:suggest"),("put on something else","music:next"),("play brown rang","music:song"),
])
add("music_hinglish",[
("gaana pause karo","music:pause"),("gaana band karo","music:pause"),("music rok do","music:pause"),
("agla gaana chalao","music:next"),("gaana change karo","music:next"),("ye gaana skip karo","music:next"),
("pichla gaana lagao","music:previous"),("volume thoda kam karo","music:volume"),("awaaz badha do","music:volume"),
("volume pachas kar do","music:volume"),("ye konsa gaana hai","music:nowPlaying"),("ye gaana pasand aaya","music:like"),
("mere liked songs chalao","music:likedSongs"),("kuch shaant sa chalao","music:suggest"),("koi sad gaana lagao","music:suggest"),
("arijit singh ka koi gaana chalao","music:song|music:suggest"),("laal pari chalao","music:song"),
("gaana chalu karo","music:resume"),("phir se wahi gaana chalao","music:replay"),("kuch random gaana laga do","music:random|music:suggest"),
])
add("phone_en",[
("ring my phone","tool:phone.ring"),("stop ringing","tool:phone.ring.stop"),("find my phone","tool:phone.ring|tool:phone.location"),
("where is my phone","tool:phone.location|tool:phone.ring"),("how much battery does my phone have","tool:phone.status"),
("read my messages","tool:phone.sms.read"),("read my notifications","tool:phone.notifications"),("any new notifications","tool:phone.notifications"),
("text mom i'll be late","tool:phone.sms.send",{"to":"mom"}),("call rahul","tool:phone.call",{"to":"rahul"}),
("open whatsapp on my phone","tool:phone.apps.open",{"name":"whatsapp"}),
("turn on the torch on my phone","tool:phone.torch",{"on":True}),("turn off the flashlight","tool:phone.torch",{"on":False}),
("put my phone on silent","tool:phone.ringer",{"mode":"silent"}),("turn to ring mode","tool:phone.ringer",{"mode":"normal"}),
("turn off silent mode","tool:phone.ringer",{"mode":"normal"}),("set my phone to vibrate","tool:phone.ringer",{"mode":"vibrate"}),
("turn on do not disturb","tool:phone.dnd",{"on":True}),("dnd off on my phone","tool:phone.dnd",{"on":False}),
("set an alarm for 7 am","tool:phone.alarm",{"hour":7,"minute":0}),("wake me up at 6:30","tool:phone.alarm",{"hour":6,"minute":30}),
("set a timer for 10 minutes","tool:phone.timer",{"seconds":600}),("timer for 30 seconds","tool:phone.timer",{"seconds":30}),
("remind me in an hour","tool:phone.timer",{"seconds":3600}),("lock my phone","tool:phone.lock"),
("what apps do i have on my phone","tool:phone.apps.list"),("what's on my phone clipboard","tool:phone.clipboard.get"),
("what is mom's number","tool:phone.contacts",{"name":"mom"}),("vibrate my phone","tool:phone.vibrate|tool:phone.ringer"),
])
add("mac_en",[
("turn off bluetooth on my mac","tool:mac.bluetooth",{"state":"off"}),("turn on bluetooth on my mac","tool:mac.bluetooth",{"state":"on"}),
("is bluetooth on on my mac","tool:mac.bluetooth",{"state":"status"}),("disable bluetooth","tool:mac.bluetooth",{"state":"off"}),
("turn off wifi on my mac","tool:mac.wifi",{"state":"off"}),("switch the mac wifi on","tool:mac.wifi",{"state":"on"}),
("set the mac volume to 30","tool:mac.volume|music:volume"),("how much battery does my mac have","tool:mac.status"),
("lock my mac","tool:mac.lock"),("put my mac to sleep","tool:mac.sleep"),("what apps are open on my mac","tool:mac.apps"),
("open safari","tool:mac.open",{"app":"safari"}),("open youtube.com","tool:mac.open"),("run my morning shortcut","tool:mac.shortcut",{"name":"morning"}),
("what's on my clipboard","tool:mac.clipboard.get"),("what did i copy on my mac","tool:mac.clipboard.get"),
("show a notification saying hello","tool:mac.notify"),("what app am i in","tool:mac.status"),
])
add("hinglish_tools",[
("mera phone ring karo","tool:phone.ring"),("phone dhundo","tool:phone.ring|tool:phone.location"),
("phone ki battery kitni hai","tool:phone.status"),("mere messages padho","tool:phone.sms.read"),
("notifications batao","tool:phone.notifications"),("mummy ko call karo","tool:phone.call",{"to":"mummy"}),
("rahul ko text karo ki main late hoon","tool:phone.sms.send",{"to":"rahul"}),
("torch on karo","tool:phone.torch",{"on":True}),("torch band karo","tool:phone.torch",{"on":False}),
("phone ko silent kar do","tool:phone.ringer",{"mode":"silent"}),("phone ko ring mode pe karo","tool:phone.ringer",{"mode":"normal"}),
("silent mode hata do","tool:phone.ringer",{"mode":"normal"}),("dnd on karo","tool:phone.dnd",{"on":True}),
("subah 6 baje ka alarm lagao","tool:phone.alarm",{"hour":6,"minute":0}),("10 minute ka timer lagao","tool:phone.timer",{"seconds":600}),
("ek ghante baad yaad dilana","tool:phone.timer",{"seconds":3600}),
("mac ka bluetooth band karo","tool:mac.bluetooth",{"state":"off"}),("bluetooth on karo mac ka","tool:mac.bluetooth",{"state":"on"}),
("mac ka wifi band kar do","tool:mac.wifi",{"state":"off"}),("mac ki battery kitni hai","tool:mac.status"),
("mac lock kar do","tool:mac.lock"),("mac ko sleep karo","tool:mac.sleep"),("safari kholo","tool:mac.open",{"app":"safari"}),
("phone par whatsapp kholo","tool:phone.apps.open",{"name":"whatsapp"}),("phone lock kar do","tool:phone.lock"),
])
add("asr_noise",[
("play chute vol one","music:song"),("play shoot vol 1","music:song"),("pause the musik","music:pause"),("skip ths song","music:next"),
("nex song","music:next"),("previous song please","music:previous"),("start the music","music:resume"),("what is playing right now","music:nowPlaying"),
("plays something calm","music:suggest"),("volume fourty","music:volume"),("increase the volume","music:volume"),
("turn off blue tooth on my mac","tool:mac.bluetooth",{"state":"off"}),("turn of bluetooth on my mac","tool:mac.bluetooth",{"state":"off"}),
("uh turn off the uh bluetooth on my mac","tool:mac.bluetooth",{"state":"off"}),("hey void turn off the wifi on my mac","tool:mac.wifi",{"state":"off"}),
("what's the baterry on my fone","tool:phone.status"),("ring my phon","tool:phone.ring"),("set a time for ten minutes","tool:phone.timer",{"seconds":600}),
("set an alarm for seven a m","tool:phone.alarm",{"hour":7,"minute":0}),("text mom ill be late","tool:phone.sms.send",{"to":"mom"}),
("call mum","tool:phone.call"),("read my massages","tool:phone.sms.read"),("open watsapp","tool:phone.apps.open|tool:mac.open"),
("flash light on","tool:phone.torch",{"on":True}),("go silent","tool:phone.ringer",{"mode":"silent"}),("mute my fone","tool:phone.ringer",{"mode":"silent"}),
("lock my mack","tool:mac.lock"),("turn on the wifi on my mac please","tool:mac.wifi",{"state":"on"}),
])
add("chat_en",[
("how are you","chat"),("tell me a joke","chat"),("what's the capital of france","chat"),("why is the sky blue","chat"),
("who are you","chat"),("i'm feeling tired today","chat"),("tell me something interesting","chat"),
("what is bluetooth","chat"),("how does wifi work","chat"),("my phone is so slow lately","chat"),("i hate mondays","chat"),
("explain how a battery works","chat"),("what's the best way to learn swift","chat"),("should i call my mom more often","chat"),
("write a short poem","chat"),("good morning","chat"),("thanks","chat"),("i'm bored","chat"),("what time is it","chat"),
("tell me a fun fact","chat"),("is a torch the same as a flashlight","chat"),("play a game with me","chat"),
("what does volume mean in finance","chat"),("i'm stressed about exams","chat"),("what should i eat tonight","chat"),
("what's the difference between a mac and a pc","chat"),("my mac feels slow","chat"),("do you like music","chat"),
("tell me about the song shape of you","chat"),("who wrote the song bohemian rhapsody","chat"),
])
add("chat_hinglish",[
("kya haal hai","chat"),("mujhe neend aa rahi hai","chat"),("aaj ka din bahut bura tha","chat"),("ek joke sunao","chat"),
("tum kaun ho","chat"),("mujhe kuch motivate karo","chat"),("bluetooth kya hota hai","chat"),("mera mood off hai","chat"),
("padhai mein mann nahi lag raha","chat"),("kal ka plan kya banau","chat"),("phone mein kya kya features hote hain","chat"),
("mujhe khana kya banana chahiye","chat"),("arijit singh kaun hai","chat"),("mummy ko kya gift dun","chat"),
])
add("ambiguous",[
("i'm feeling sad","chat|music:suggest"),("i need to focus","chat|music:suggest"),("play something","music:suggest"),
("stop","music:pause"),("turn it down","music:volume"),("turn it up","music:volume"),("turn it off","chat|music:pause"),
("text mom","tool:phone.sms.send|tool:phone.call|chat"),("call","chat"),("what's the volume","chat|music:volume|tool:mac.volume"),
("open it","chat"),("do it again","chat|music:replay"),("battery","tool:phone.status|tool:mac.status|chat"),
("what's up with my phone","chat|tool:phone.status"),("silent","tool:phone.ringer|chat"),
])
import collections
cnt=collections.Counter()
with open('router_eval.jsonl','w') as f:
    for s,t,e,a in C:
        cnt[s]+=1
        row={"id":f"{s}-{cnt[s]:02d}","slice":s,"text":t,"expect":e}
        if a: row["args"]=a
        f.write(json.dumps(row,ensure_ascii=False)+"\n")
print(len(C),dict(cnt))
