/* Original practice material written for sat.denduluru.com. */
window.SAT_RW_QUESTIONS = [
  {
    id: 'rwq001', number: 1, domain: 'Information and Ideas', skill: 'Central Ideas and Details', difficulty: 'Easy',
    passage: 'Several cities have begun installing solar panels above irrigation canals. The panels generate electricity while shading the water, which can reduce evaporation. Because the canals already occupy cleared land, the projects can also avoid some of the habitat disruption associated with building large solar farms.',
    prompt: 'Which choice best states the main idea of the text?',
    choices: [
      'Solar panels are too expensive for most irrigation systems.',
      'Placing solar panels over canals can provide multiple environmental benefits.',
      'Cities should replace irrigation canals with solar farms.',
      'Evaporation is the largest source of energy loss in cities.'
    ],
    answerIndex: 1,
    explanation: 'The text emphasizes three benefits of canal-top solar panels: electricity generation, reduced evaporation, and less need to disturb habitat.',
    distractors: [
      'The passage does not discuss the panels’ cost.',
      '',
      'The projects use existing canals rather than replacing them.',
      'The passage discusses water loss, not energy loss, and makes no claim that it is the largest urban problem.'
    ],
    strategy: 'Combine the points repeated across the entire passage rather than choosing one isolated detail.'
  },
  {
    id: 'rwq002', number: 2, domain: 'Information and Ideas', skill: 'Central Ideas and Details', difficulty: 'Medium',
    passage: 'Art conservator Lena Ortiz tested three blue pigments found on a nineteenth-century theater curtain. One pigment faded rapidly under gallery lighting, whereas the other two remained stable. Ortiz recommended limiting the curtain’s exposure to light because even a small amount of the unstable pigment could alter the balance of colors across the whole design.',
    prompt: 'According to the text, why did Ortiz recommend limiting the curtain’s exposure to light?',
    choices: [
      'The theater curtain was originally displayed outdoors.',
      'All three blue pigments faded at the same rate.',
      'One pigment’s fading could change the appearance of the entire design.',
      'Gallery lighting made the stable pigments appear brighter.'
    ],
    answerIndex: 2,
    explanation: 'Ortiz was concerned that the unstable pigment would fade and disrupt the design’s overall color balance.',
    distractors: [
      'The location of the curtain’s original display is not mentioned.',
      'The passage says that two pigments remained stable.',
      '',
      'The passage does not say that the stable pigments became brighter.'
    ],
    strategy: 'For a detail question, return to the sentence that directly explains the recommendation.'
  },
  {
    id: 'rwq003', number: 3, domain: 'Information and Ideas', skill: 'Inferences', difficulty: 'Hard',
    passage: 'Ecologist Priya Raman grew identical grass seedlings in soils containing different communities of mycorrhizal fungi. During a simulated drought, seedlings associated with one fungal community retained more water than seedlings in the other soils. After normal watering resumed, however, all groups recovered at nearly the same rate.',
    prompt: 'Which choice most logically follows from the text?',
    choices: [
      'Every community of mycorrhizal fungi prevents drought damage completely.',
      'The fungal communities affected water retention during drought more than recovery afterward.',
      'The seedlings without fungi recovered faster than all other seedlings.',
      'Normal watering eliminated the fungi from the soil.'
    ],
    answerIndex: 1,
    explanation: 'The groups differed in water retention during drought but recovered at nearly the same rate after watering resumed.',
    distractors: [
      'The passage reports a difference in degree, not complete prevention of damage.',
      '',
      'No group is identified as lacking fungi, and recovery rates were nearly the same.',
      'The passage gives no evidence that watering removed the fungi.'
    ],
    strategy: 'An inference must be supported by the stated comparison without adding a new cause or result.'
  },
  {
    id: 'rwq004', number: 4, domain: 'Information and Ideas', skill: 'Command of Evidence', difficulty: 'Medium',
    passage: 'A researcher claims that mature trees can make paved urban spaces more comfortable during hot weather by cooling the surfaces beneath them.',
    prompt: 'Which finding, if true, would most directly support the researcher’s claim?',
    choices: [
      'Tree-lined streets contained more species of birds than streets without trees.',
      'At midday, shaded pavement averaged 12°F cooler than nearby unshaded pavement.',
      'Residents preferred flowering trees to trees without visible flowers.',
      'Some tree roots damaged sidewalks that had been installed decades earlier.'
    ],
    answerIndex: 1,
    explanation: 'A direct temperature comparison between shaded and unshaded pavement supports the claim that trees cool paved surfaces.',
    distractors: [
      'Bird diversity does not measure surface cooling.',
      '',
      'Aesthetic preference does not test the temperature claim.',
      'Sidewalk damage is unrelated to cooling.'
    ],
    strategy: 'Match the evidence to every important part of the claim: mature trees, paved surfaces, and cooling.'
  },
  {
    id: 'rwq005', number: 5, domain: 'Information and Ideas', skill: 'Command of Evidence', difficulty: 'Hard',
    passage: 'A biology class compared pollinator visits to school gardens containing different numbers of native flowering plant species. The students concluded that gardens with greater plant diversity generally attracted more pollinator visits per hour.',
    table: {
      caption: 'Average pollinator visits per hour',
      headers: ['Garden', 'Native plant species', 'Visits per hour'],
      rows: [['A', '2', '7'], ['B', '4', '13'], ['C', '6', '19'], ['D', '8', '18']]
    },
    prompt: 'Which choice best uses the table to support the students’ conclusion?',
    choices: [
      'Garden A had 2 species and 7 visits, while Garden C had 6 species and 19 visits.',
      'Gardens C and D differed by 2 species but only 1 visit per hour.',
      'Garden D had fewer visits than Garden C despite having more species.',
      'The four gardens contained a total of 20 native plant species.'
    ],
    answerIndex: 0,
    explanation: 'The comparison between Gardens A and C shows that the garden with more species also had substantially more visits.',
    distractors: [
      '',
      'This narrow comparison does not clearly demonstrate the general upward pattern.',
      'This points to an exception rather than supporting the general conclusion.',
      'The total number of species does not connect diversity in individual gardens with visit rates.'
    ],
    strategy: 'Choose numbers that clearly demonstrate the relationship named in the claim.'
  },
  {
    id: 'rwq006', number: 6, domain: 'Information and Ideas', skill: 'Central Ideas and Details', difficulty: 'Easy',
    passage: 'Mara reached the community hall before anyone else. She arranged the folding chairs in careful rows, tested the microphone twice, and placed handwritten welcome cards at every seat. When the first guest arrived, Mara stepped behind the curtain, content to let the event itself receive the attention.',
    prompt: 'Which choice best describes Mara as presented in the text?',
    choices: [
      'She is prepared and prefers working without recognition.',
      'She is uncertain whether the event should occur.',
      'She is annoyed that the guests arrived late.',
      'She is eager to speak to the entire audience.'
    ],
    answerIndex: 0,
    explanation: 'Mara prepares the room carefully and then moves out of sight, showing both diligence and a lack of interest in recognition.',
    distractors: [
      '',
      'Her careful preparations indicate commitment, not uncertainty.',
      'The passage never says the guests are late or that Mara is annoyed.',
      'She steps behind the curtain rather than seeking the microphone.'
    ],
    strategy: 'Character questions are answered through actions and choices, not unsupported labels.'
  },
  {
    id: 'rwq007', number: 7, domain: 'Information and Ideas', skill: 'Inferences', difficulty: 'Medium',
    passage: 'Before standardized time zones, many towns set their clocks according to the sun’s local position. This system became inconvenient as rail travel expanded: a schedule covering hundreds of towns could contain dozens of slightly different local times. Railroad companies therefore adopted shared regional times before many governments formally did so.',
    prompt: 'The text most strongly suggests that railroad companies adopted regional times primarily to',
    choices: [
      'reduce confusion when coordinating travel schedules.',
      'encourage governments to regulate the rail industry.',
      'make trains travel faster between distant towns.',
      'preserve each town’s traditional method of setting clocks.'
    ],
    answerIndex: 0,
    explanation: 'The many local times made multistop schedules difficult to coordinate, so shared regional times simplified scheduling.',
    distractors: [
      '',
      'Government regulation is not identified as the companies’ purpose.',
      'Changing clocks does not change the physical speed of trains.',
      'Regional time replaced rather than preserved separate local times.'
    ],
    strategy: 'Connect the stated problem in one sentence to the solution introduced in the next.'
  },
  {
    id: 'rwq008', number: 8, domain: 'Information and Ideas', skill: 'Command of Evidence', difficulty: 'Hard',
    passage: 'Marine scientists tested three methods for attaching young corals to damaged reefs. They argue that Method B offers the best balance of high survival and efficient installation.',
    table: {
      caption: 'Coral restoration results after six months',
      headers: ['Method', 'Coral survival', 'Minutes per coral'],
      rows: [['A', '82%', '12'], ['B', '79%', '5'], ['C', '61%', '4']]
    },
    prompt: 'Which choice best supports the scientists’ argument?',
    choices: [
      'Method A had the highest survival rate but also required the most installation time.',
      'Method B’s survival rate was close to Method A’s, but Method B required less than half as much installation time.',
      'Method C required one minute less per coral than Method B.',
      'Every method had a survival rate greater than 50%.'
    ],
    answerIndex: 1,
    explanation: 'Method B sacrifices only 3 percentage points of survival compared with A while cutting installation time from 12 to 5 minutes.',
    distractors: [
      'This describes Method A’s tradeoff but does not establish why B has the best balance.',
      '',
      'This addresses efficiency only and ignores C’s much lower survival rate.',
      'The statement is true but does not distinguish Method B from the alternatives.'
    ],
    strategy: 'When a claim says “best balance,” the evidence must compare both measures, not just one.'
  },
  {
    id: 'rwq009', number: 9, domain: 'Information and Ideas', skill: 'Command of Evidence', difficulty: 'Medium',
    passage: 'Ornithologist Caleb Wu hypothesizes that chronic traffic noise causes some city birds to alter the pitch of their calls so that other birds can hear them more easily.',
    prompt: 'Which study result would most directly support Wu’s hypothesis?',
    choices: [
      'Birds near busy roads used higher-pitched calls than birds of the same species in quiet parks.',
      'More bird species lived in large parks than in small parks.',
      'Traffic volume was greater on weekdays than on weekends.',
      'Some birds built nests on buildings instead of in trees.'
    ],
    answerIndex: 0,
    explanation: 'The result links exposure to traffic noise with a difference in call pitch within the same species.',
    distractors: [
      '',
      'Species counts do not test changes in call pitch.',
      'Traffic patterns alone provide no information about birds’ calls.',
      'Nest location is unrelated to the hypothesized vocal change.'
    ],
    strategy: 'The strongest evidence directly measures both the proposed cause and the proposed effect.'
  },
  {
    id: 'rwq010', number: 10, domain: 'Information and Ideas', skill: 'Central Ideas and Details', difficulty: 'Easy',
    passage: 'In a memory study, participants learned pairs of unfamiliar symbols. One group then slept for eight hours, while another remained awake for the same period. When tested, the sleep group remembered more pairs. The researchers cautioned, however, that the study did not determine which stage of sleep was most important.',
    prompt: 'Which choice is a detail stated in the text?',
    choices: [
      'The researchers identified the exact sleep stage responsible for memory.',
      'Participants studied familiar words rather than symbols.',
      'The group that slept remembered more symbol pairs.',
      'Both groups slept for eight hours before testing.'
    ],
    answerIndex: 2,
    explanation: 'The passage explicitly states that the sleep group remembered more pairs.',
    distractors: [
      'The researchers specifically said they had not identified the most important sleep stage.',
      'The symbols were unfamiliar.',
      '',
      'Only one group slept; the other stayed awake.'
    ],
    strategy: 'A stated-detail answer should closely paraphrase an explicit sentence.'
  },
  {
    id: 'rwq011', number: 11, domain: 'Craft and Structure', skill: 'Words in Context', difficulty: 'Easy',
    passage: 'Because the experiment included only twelve participants, the researchers described their conclusion as tentative and recommended a larger follow-up study.',
    prompt: 'As used in the text, what does “tentative” most nearly mean?',
    choices: ['Temporary and uncertain', 'Secretly planned', 'Highly detailed', 'Widely accepted'],
    answerIndex: 0,
    explanation: 'The small sample and request for more research show that the conclusion is preliminary rather than final.',
    distractors: ['', 'Nothing suggests the conclusion was secret.', 'The word describes certainty, not level of detail.', 'A conclusion needing confirmation is not yet widely accepted.'],
    strategy: 'Use the surrounding cause and consequence to determine the word’s meaning.'
  },
  {
    id: 'rwq012', number: 12, domain: 'Craft and Structure', skill: 'Words in Context', difficulty: 'Medium',
    passage: 'The museum’s director argued that ticket sales alone could not sustain the free education programs. Donations would also be needed to keep the programs operating throughout the year.',
    prompt: 'As used in the text, what does “sustain” most nearly mean?',
    choices: ['Prove', 'Continue supporting', 'Publicly advertise', 'Reduce the size of'],
    answerIndex: 1,
    explanation: 'The following sentence explains that more funding is needed to keep the programs operating.',
    distractors: ['The issue is funding, not proving the programs’ value.', '', 'Advertising is not discussed.', 'The goal is to keep the programs operating, not shrink them.'],
    strategy: 'Replace the tested word with each choice and check which preserves the sentence’s logic.'
  },
  {
    id: 'rwq013', number: 13, domain: 'Craft and Structure', skill: 'Words in Context', difficulty: 'Medium',
    passage: 'To ______ the effects of flooding, the town restored wetlands that can temporarily hold stormwater before it reaches residential streets.',
    prompt: 'Which choice completes the text with the most logical and precise word?',
    choices: ['imitate', 'document', 'mitigate', 'predict'],
    answerIndex: 2,
    explanation: '“Mitigate” means to make something harmful less severe, which matches the wetlands’ role in reducing flood effects.',
    distractors: ['The wetlands reduce flooding rather than copy it.', 'Recording flood effects would not explain holding stormwater.', '', 'The sentence describes reducing effects, not forecasting them.'],
    strategy: 'Predict the needed meaning before looking at the answer choices.'
  },
  {
    id: 'rwq014', number: 14, domain: 'Craft and Structure', skill: 'Text Structure and Purpose', difficulty: 'Easy',
    passage: 'Some materials expand when heated. A metal jar lid, for example, may loosen after warm water is poured over it because the metal expands slightly.',
    prompt: 'Which choice best describes the function of the second sentence in the text?',
    choices: [
      'It challenges the general statement in the first sentence.',
      'It provides a familiar example of the principle in the first sentence.',
      'It explains why all materials react identically to heat.',
      'It introduces a competing scientific theory.'
    ],
    answerIndex: 1,
    explanation: 'The jar lid illustrates the general principle that some materials expand when heated.',
    distractors: ['The example supports rather than challenges the first sentence.', '', 'The first sentence says “some,” not all, materials.', 'No competing theory is introduced.'],
    strategy: 'Name the relationship between the sentences: example, contrast, cause, definition, or conclusion.'
  },
  {
    id: 'rwq015', number: 15, domain: 'Craft and Structure', skill: 'Text Structure and Purpose', difficulty: 'Hard',
    passage: 'For decades, historians assumed that a coastal settlement imported nearly all its pottery. Recent chemical analysis, however, matched the clay in several vessels to deposits located less than ten miles away. The finding does not prove that every vessel was locally made, but it requires historians to reconsider the settlement’s role as a producer.',
    prompt: 'What is the main purpose of the final sentence?',
    choices: [
      'To reject chemical analysis as an unreliable research method',
      'To qualify the finding while explaining how it changes an earlier interpretation',
      'To claim that the settlement exported pottery throughout the region',
      'To identify the exact workshop where every vessel was produced'
    ],
    answerIndex: 1,
    explanation: 'The sentence limits the finding (“does not prove”) but also states its significance: historians must reconsider the settlement as a producer.',
    distractors: ['The chemical analysis is treated as meaningful evidence.', '', 'Exporting pottery is not discussed.', 'The sentence explicitly avoids claiming that every vessel was local.'],
    strategy: 'Notice contrast words such as “but”; they often reveal a sentence’s two-part function.'
  },
  {
    id: 'rwq016', number: 16, domain: 'Craft and Structure', skill: 'Cross-Text Connections', difficulty: 'Medium',
    text1: 'Text 1: Economist Dana Lee argues that remote work can help small towns retain residents by allowing people to pursue jobs based elsewhere. She notes that this benefit depends on reliable broadband access.',
    text2: 'Text 2: Planner Omar Ruiz reports that several small towns gained remote workers after expanding high-speed internet service. He cautions that housing supply must also grow if those gains are to continue.',
    prompt: 'Based on the texts, Lee and Ruiz would most likely agree that',
    choices: [
      'remote work will eliminate the need for local businesses.',
      'broadband infrastructure can help small towns attract or retain remote workers.',
      'housing supply has no effect on population growth.',
      'all jobs can be performed remotely.'
    ],
    answerIndex: 1,
    explanation: 'Both writers connect reliable or high-speed internet with the ability of small towns to benefit from remote work.',
    distractors: ['Neither writer makes this claim.', '', 'Ruiz specifically says housing supply matters.', 'Neither text says that every job can be remote.'],
    strategy: 'Find the overlapping claim supported by both texts, even if each writer adds a different caution.'
  },
  {
    id: 'rwq017', number: 17, domain: 'Craft and Structure', skill: 'Cross-Text Connections', difficulty: 'Hard',
    text1: 'Text 1: Biologist Mei Chen proposes closing a popular trail during the entire nesting season of a threatened shorebird. Even occasional hikers, she argues, can cause adult birds to leave nests unattended.',
    text2: 'Text 2: Biologist Arturo Silva agrees that disturbance is harmful but recommends limiting access only during the morning, when nesting activity is greatest. He points to observations showing little response to hikers later in the day.',
    prompt: 'How would Silva most likely respond to Chen’s proposal?',
    choices: [
      'He would support it because he believes all human activity harms every bird species.',
      'He would oppose any restriction because the observations show no disturbance.',
      'He would consider it broader than necessary because he favors restrictions during the most sensitive hours.',
      'He would argue that the trail should be widened before nesting season.'
    ],
    answerIndex: 2,
    explanation: 'Silva accepts the need for protection but favors a targeted morning closure, so he would view a full-season, all-day closure as unnecessarily broad.',
    distractors: ['Silva does not claim that all activity harms every species.', 'He agrees that disturbance is harmful and recommends a restriction.', '', 'Trail width is not discussed.'],
    strategy: 'Separate the shared principle from the specific policy on which the authors differ.'
  },
  {
    id: 'rwq018', number: 18, domain: 'Craft and Structure', skill: 'Words in Context', difficulty: 'Easy',
    passage: 'The engineer proposed a novel method for storing heat: instead of warming water, the system would melt and later solidify a salt-based material.',
    prompt: 'As used in the text, what does “novel” most nearly mean?',
    choices: ['Fictional', 'New and original', 'Lengthy', 'Risk-free'],
    answerIndex: 1,
    explanation: 'The colon introduces an unusual alternative method, so “novel” means new or original.',
    distractors: ['“Novel” can refer to a book, but that meaning does not fit here.', '', 'The sentence does not discuss length.', 'New methods are not necessarily free of risk.'],
    strategy: 'Choose the meaning that fits the local context, not merely a familiar dictionary meaning.'
  },
  {
    id: 'rwq019', number: 19, domain: 'Craft and Structure', skill: 'Text Structure and Purpose', difficulty: 'Medium',
    passage: 'Readers often imagine medieval manuscripts as uniformly solemn objects. Yet scribes sometimes drew playful creatures in the margins: rabbits dueling with swords, snails confronting knights, and musicians with animal heads. These images remind modern readers that humor existed alongside serious religious and scholarly work.',
    prompt: 'Which choice best describes the overall structure of the text?',
    choices: [
      'It presents a common assumption, offers contrasting examples, and explains their significance.',
      'It lists several manuscripts and ranks them by artistic quality.',
      'It describes a historical problem and proposes a modern solution.',
      'It compares two scribes’ explanations of the same drawing.'
    ],
    answerIndex: 0,
    explanation: 'The passage begins with a common image of manuscripts, contrasts it with humorous examples, and concludes with what those examples reveal.',
    distractors: ['', 'No manuscripts are named or ranked.', 'No problem-solution structure appears.', 'No individual scribes or competing explanations are given.'],
    strategy: 'Summarize what each sentence does, then combine those functions in order.'
  },
  {
    id: 'rwq020', number: 20, domain: 'Craft and Structure', skill: 'Cross-Text Connections', difficulty: 'Hard',
    text1: 'Text 1: Literary critic Anika Bose argues that footnotes in historical novels can deepen immersion by helping readers understand unfamiliar customs without interrupting the main narrative.',
    text2: 'Text 2: Novelist Paul Egan avoids footnotes because, in his view, moving between the story and explanatory notes reminds readers that the fictional world has been constructed.',
    prompt: 'The authors of the texts disagree primarily about whether footnotes',
    choices: [
      'should contain information about historical customs.',
      'are more appropriate in nonfiction than in fiction.',
      'strengthen or weaken a reader’s sense of immersion in a historical novel.',
      'can be placed at the bottom of a printed page.'
    ],
    answerIndex: 2,
    explanation: 'Bose says footnotes deepen immersion, whereas Egan says they disrupt immersion by drawing attention to the novel’s construction.',
    distractors: ['Only Text 1 specifies the kind of information footnotes might contain.', 'Neither text compares fiction with nonfiction.', '', 'The physical placement of footnotes is not at issue.'],
    strategy: 'State each author’s position in parallel terms and identify the exact point of conflict.'
  },
  {
    id: 'rwq021', number: 21, domain: 'Expression of Ideas', skill: 'Transitions', difficulty: 'Easy',
    passage: 'The first prototype was inexpensive to manufacture. ______, it broke after only a few hours of use, so the designers revised the material.',
    prompt: 'Which choice completes the text with the most logical transition?',
    choices: ['Similarly,', 'However,', 'For example,', 'Therefore,'],
    answerIndex: 1,
    explanation: 'The second sentence contrasts the prototype’s low cost with its poor durability, so “However” is appropriate.',
    distractors: ['“Similarly” signals likeness, not contrast.', '', 'The second sentence is not an example of low manufacturing cost.', 'The failure is not a result of the low cost as stated.'],
    strategy: 'Identify the relationship between the ideas before choosing a transition.'
  },
  {
    id: 'rwq022', number: 22, domain: 'Expression of Ideas', skill: 'Transitions', difficulty: 'Medium',
    passage: 'The library’s roof receives direct sunlight for most of the day. ______, the building is a strong candidate for rooftop solar panels.',
    prompt: 'Which choice completes the text with the most logical transition?',
    choices: ['Nevertheless,', 'Meanwhile,', 'Consequently,', 'In contrast,'],
    answerIndex: 2,
    explanation: 'The suitability for solar panels is a result of the roof’s sunlight exposure, so “Consequently” fits.',
    distractors: ['“Nevertheless” signals an unexpected contrast.', '“Meanwhile” signals events occurring at the same time.', '', 'No contrast is presented.'],
    strategy: 'When the second statement follows as a result of the first, use a cause-and-effect transition.'
  },
  {
    id: 'rwq023', number: 23, domain: 'Expression of Ideas', skill: 'Transitions', difficulty: 'Medium',
    passage: 'The new bus route connects the neighborhood to the hospital. ______, it provides direct service to the community college.',
    prompt: 'Which choice completes the text with the most logical transition?',
    choices: ['Moreover,', 'Instead,', 'Nevertheless,', 'Previously,'],
    answerIndex: 0,
    explanation: 'The second sentence adds another benefit of the bus route, so “Moreover” is logical.',
    distractors: ['', '“Instead” would indicate a replacement.', '“Nevertheless” would introduce a contrast.', '“Previously” refers to time, not addition.'],
    strategy: 'Ask whether the second idea adds, contrasts, causes, exemplifies, or sequences.'
  },
  {
    id: 'rwq024', number: 24, domain: 'Expression of Ideas', skill: 'Transitions', difficulty: 'Easy',
    passage: 'Many desert plants have features that conserve water. ______, the waxy coating on a cactus can reduce moisture loss from its surface.',
    prompt: 'Which choice completes the text with the most logical transition?',
    choices: ['On the contrary,', 'For instance,', 'As a result,', 'Nevertheless,'],
    answerIndex: 1,
    explanation: 'The cactus coating is a specific example of a water-conserving feature.',
    distractors: ['The sentence does not contradict the general statement.', '', 'The cactus feature is an example, not a result of the general statement.', 'No unexpected contrast is present.'],
    strategy: 'A broad statement followed by one specific case usually calls for an example transition.'
  },
  {
    id: 'rwq025', number: 25, domain: 'Expression of Ideas', skill: 'Transitions', difficulty: 'Hard',
    passage: 'The research team initially expected the coating to repel all liquids. In early tests, water rolled off the coated surface. Oil, ______, spread across it, revealing that the coating’s effect depended on the liquid.',
    prompt: 'Which choice completes the text with the most logical transition?',
    choices: ['in addition,', 'for example,', 'by contrast,', 'therefore,'],
    answerIndex: 2,
    explanation: 'Oil behaved differently from water, so “by contrast” clearly signals the opposing test results.',
    distractors: ['The point is not merely an additional similar result.', 'Oil is not another example of liquid being repelled.', '', 'The oil’s behavior is not presented as a result of water rolling off.'],
    strategy: 'Look beyond adjacent sentences and identify the comparison the writer is emphasizing.'
  },
  {
    id: 'rwq026', number: 26, domain: 'Expression of Ideas', skill: 'Rhetorical Synthesis', difficulty: 'Easy',
    notes: [
      'In 1912, Garrett Morgan received a patent for a breathing device.',
      'The device supplied cleaner air through a long tube near the ground.',
      'In 1916, rescuers used Morgan’s device after an explosion in a tunnel beneath Lake Erie.'
    ],
    prompt: 'The student wants to emphasize the sequence of events. Which choice most effectively uses relevant information from the notes?',
    choices: [
      'Garrett Morgan’s breathing device supplied air through a tube near the ground.',
      'After patenting a breathing device in 1912, Garrett Morgan saw it used by tunnel rescuers in 1916.',
      'A tunnel beneath Lake Erie was the site of an explosion in 1916.',
      'Rescuers sometimes need breathing devices that provide cleaner air.'
    ],
    answerIndex: 1,
    explanation: 'The sentence uses both dates and “after” to clearly present the patent followed by the rescue use.',
    distractors: ['This describes the device but not the sequence.', '', 'This gives only the later event.', 'This is a general statement not supported as a sequence in the notes.'],
    strategy: 'Honor the stated writing goal; include only details that help accomplish it.'
  },
  {
    id: 'rwq027', number: 27, domain: 'Expression of Ideas', skill: 'Rhetorical Synthesis', difficulty: 'Medium',
    notes: [
      'Sculptor Eliana Park created Tide Line in 2018 using steel wire.',
      'The sculpture’s curved form resembles an ocean wave.',
      'Park created Harbor Grid in 2021 using straight wooden slats.',
      'Harbor Grid resembles the rectangular pattern of city streets.'
    ],
    prompt: 'The student wants to compare the forms and materials of the two works. Which choice most effectively uses relevant information from the notes?',
    choices: [
      'Eliana Park created Tide Line in 2018 and Harbor Grid in 2021.',
      'Tide Line resembles an ocean wave, and Harbor Grid resembles city streets.',
      'Whereas Tide Line uses curved steel wire to suggest a wave, Harbor Grid uses straight wooden slats to evoke city streets.',
      'Eliana Park is a sculptor who works with more than one material.'
    ],
    answerIndex: 2,
    explanation: 'The sentence directly compares both form (curved versus straight), material (steel versus wood), and visual effect.',
    distractors: ['This compares dates but not forms or materials.', 'This compares appearance but omits materials.', '', 'This generalization omits the specific comparison requested.'],
    strategy: 'For a comparison goal, use parallel details about both subjects.'
  },
  {
    id: 'rwq028', number: 28, domain: 'Expression of Ideas', skill: 'Rhetorical Synthesis', difficulty: 'Medium',
    notes: [
      'Geologist Farah Nasser studies tiny crystals in volcanic rock.',
      'The crystals can trap small amounts of water and gas.',
      'Nasser analyzes the trapped material to estimate pressure inside a volcano before an eruption.'
    ],
    prompt: 'The student wants to introduce Nasser and explain the purpose of her research. Which choice most effectively uses relevant information from the notes?',
    choices: [
      'Volcanic rock can contain crystals, water, and gas.',
      'Geologist Farah Nasser analyzes water and gas trapped in volcanic crystals to estimate pre-eruption pressure.',
      'Farah Nasser is a geologist, and volcanoes sometimes erupt under pressure.',
      'Tiny crystals are found in volcanic rock studied by scientists.'
    ],
    answerIndex: 1,
    explanation: 'The sentence identifies Nasser and concisely connects what she analyzes with why she analyzes it.',
    distractors: ['This does not introduce Nasser or explain her purpose.', '', 'This mentions her field but does not accurately describe her research method.', 'This neither introduces Nasser by name nor explains the purpose.'],
    strategy: 'Include the person, the action, and the research purpose when the goal asks for all three.'
  },
  {
    id: 'rwq029', number: 29, domain: 'Expression of Ideas', skill: 'Rhetorical Synthesis', difficulty: 'Hard',
    notes: [
      'A vacant lot on Mercer Street covers two acres.',
      'The neighborhood has no public playground within one mile.',
      'A city survey found that 68% of nearby households include children.',
      'The parks department estimates that converting the lot would cost $420,000.'
    ],
    prompt: 'The student wants to persuade the city council that the lot would be a useful location for a playground. Which choice most effectively uses relevant information from the notes?',
    choices: [
      'The parks department estimates that a playground would cost $420,000.',
      'Mercer Street contains a vacant two-acre lot in a neighborhood where 68% of households include children and no public playground exists within a mile.',
      'A city survey collected information about households near Mercer Street.',
      'Some vacant lots are converted into playgrounds, while others remain undeveloped.'
    ],
    answerIndex: 1,
    explanation: 'The sentence combines the available space, the likely users, and the lack of an existing playground—the evidence most relevant to usefulness.',
    distractors: ['Cost alone does not establish that the location would be useful.', '', 'This mentions a survey without its persuasive result.', 'This unsupported generalization does not use the key local evidence.'],
    strategy: 'Select evidence that directly advances the persuasive goal rather than including every note.'
  },
  {
    id: 'rwq030', number: 30, domain: 'Expression of Ideas', skill: 'Rhetorical Synthesis', difficulty: 'Hard',
    notes: [
      'Bioluminescence is light produced by a chemical reaction inside a living organism.',
      'Some deep-sea animals use bioluminescence to attract prey.',
      'Other animals use it to confuse predators or communicate with members of their species.'
    ],
    prompt: 'The student wants to define bioluminescence for an audience unfamiliar with the term and mention its varied uses. Which choice most effectively uses relevant information from the notes?',
    choices: [
      'Deep-sea animals may need to attract prey, confuse predators, or communicate.',
      'Bioluminescence has several uses among organisms that live in the sea.',
      'Bioluminescence—light created by a chemical reaction within an organism—can help animals attract prey, confuse predators, or communicate.',
      'A chemical reaction can occur inside a living organism.'
    ],
    answerIndex: 2,
    explanation: 'The sentence both defines the unfamiliar term and efficiently lists the different uses in the notes.',
    distractors: ['This lists uses but does not define bioluminescence.', 'This mentions varied uses but gives neither a definition nor examples.', '', 'This provides part of the definition but never names or explains bioluminescence.'],
    strategy: 'When writing for an unfamiliar audience, define the term before adding examples or applications.'
  },
  {
    id: 'rwq031', number: 31, domain: 'Standard English Conventions', skill: 'Boundaries', difficulty: 'Easy',
    passage: 'The storm ended before sunrise ______ the cleanup crews began work at six o’clock.',
    prompt: 'Which choice completes the text so that it conforms to the conventions of Standard English?',
    choices: [', and', ', however,', '; and,', ': but'],
    answerIndex: 0,
    explanation: 'The sentence contains two independent clauses. A comma followed by the coordinating conjunction “and” correctly joins them.',
    distractors: ['', '“However” would require a semicolon or period before it in this structure.', 'A semicolon should not be followed by “and” plus a comma.', 'A colon followed by “but” does not correctly join these clauses.'],
    strategy: 'Check whether the words on both sides can stand as complete sentences.'
  },
  {
    id: 'rwq032', number: 32, domain: 'Standard English Conventions', skill: 'Boundaries', difficulty: 'Medium',
    passage: 'The exhibition features three types of handmade objects ______ woven baskets, carved masks, and painted bowls.',
    prompt: 'Which choice completes the text so that it conforms to the conventions of Standard English?',
    choices: [',', ';', ':', '— and'],
    answerIndex: 2,
    explanation: 'A colon correctly introduces the list because the words before the blank form a complete clause.',
    distractors: ['A comma alone cannot properly introduce this list after a complete clause.', 'A semicolon does not introduce a list in this construction.', '', 'The dash plus “and” is unnecessary and disrupts the sentence.'],
    strategy: 'Use a colon after a complete clause to introduce a list, explanation, or example.'
  },
  {
    id: 'rwq033', number: 33, domain: 'Standard English Conventions', skill: 'Form, Structure, and Sense', difficulty: 'Easy',
    passage: 'The two ______ recommendations differed, but both emphasized the need for additional testing.',
    prompt: 'Which choice completes the text so that it conforms to the conventions of Standard English?',
    choices: ["scientist's", "scientists", "scientists'", "scientist"],
    answerIndex: 2,
    explanation: 'The recommendations belong to two scientists, so the plural possessive form “scientists’” is required.',
    distractors: ['This singular possessive refers to one scientist.', 'This plural form is not possessive.', '', 'This singular noun is neither plural nor possessive.'],
    strategy: 'First decide whether the noun is singular or plural, then decide whether it shows possession.'
  },
  {
    id: 'rwq034', number: 34, domain: 'Standard English Conventions', skill: 'Form, Structure, and Sense', difficulty: 'Medium',
    passage: 'A collection of letters from the expedition ______ in the university archive.',
    prompt: 'Which choice completes the text so that it conforms to the conventions of Standard English?',
    choices: ['are stored', 'were storing', 'is stored', 'have stored'],
    answerIndex: 2,
    explanation: 'The subject is the singular noun “collection,” so the singular verb phrase “is stored” agrees with it.',
    distractors: ['This incorrectly agrees with the nearby plural noun “letters.”', 'This does not form a logical passive construction.', '', 'This plural active verb does not agree with “collection” or express the intended meaning.'],
    strategy: 'Ignore interrupting prepositional phrases when locating the true subject.'
  },
  {
    id: 'rwq035', number: 35, domain: 'Standard English Conventions', skill: 'Form, Structure, and Sense', difficulty: 'Medium',
    passage: 'Neither the conductor nor the musicians ______ satisfied with the hall’s acoustics during rehearsal.',
    prompt: 'Which choice completes the text so that it conforms to the conventions of Standard English?',
    choices: ['was', 'has been', 'were', 'is'],
    answerIndex: 2,
    explanation: 'With “neither...nor,” the verb agrees with the nearer subject. “Musicians” is plural, so “were” is correct.',
    distractors: ['“Was” is singular and does not agree with the nearer subject.', 'This singular verb phrase does not agree and changes the tense.', '', '“Is” is singular and shifts the sentence from past to present.'],
    strategy: 'With paired subjects joined by “neither...nor,” check the noun closest to the verb.'
  },
  {
    id: 'rwq036', number: 36, domain: 'Standard English Conventions', skill: 'Form, Structure, and Sense', difficulty: 'Easy',
    passage: 'By the time the lecture began, the technicians ______ the sound system three times.',
    prompt: 'Which choice completes the text so that it conforms to the conventions of Standard English?',
    choices: ['test', 'had tested', 'will test', 'are testing'],
    answerIndex: 1,
    explanation: 'The testing was completed before another past event, so the past perfect “had tested” is appropriate.',
    distractors: ['Simple present does not fit the past timeline.', '', 'Future tense contradicts “by the time...began.”', 'Present progressive does not show completed earlier action.'],
    strategy: 'Use past perfect for an action completed before another past action.'
  },
  {
    id: 'rwq037', number: 37, domain: 'Standard English Conventions', skill: 'Form, Structure, and Sense', difficulty: 'Hard',
    passage: 'Walking through the restored wetland, ______',
    prompt: 'Which choice completes the text so that it conforms to the conventions of Standard English?',
    choices: [
      'several herons were visible to the visitors.',
      'the visitors spotted several herons.',
      'there were several herons spotted by visitors.',
      'the sight of several herons delighted the visitors.'
    ],
    answerIndex: 1,
    explanation: 'The noun immediately after the introductory phrase must be the one doing the walking. “The visitors” logically perform that action.',
    distractors: ['This illogically suggests that the herons were walking through the wetland as visitors.', '', 'The introductory phrase does not logically modify “there.”', 'The phrase would illogically modify “the sight” as the thing walking.'],
    strategy: 'Place the person or thing performing an introductory action immediately after the comma.'
  },
  {
    id: 'rwq038', number: 38, domain: 'Standard English Conventions', skill: 'Form, Structure, and Sense', difficulty: 'Medium',
    passage: 'The internship requires participants to collect samples, to record observations, and ______',
    prompt: 'Which choice completes the text so that it conforms to the conventions of Standard English?',
    choices: ['analyzing the results.', 'they analyze results.', 'to analyze the results.', 'the results are analyzed.'],
    answerIndex: 2,
    explanation: 'The third item should match the “to collect” and “to record” structure: “to analyze.”',
    distractors: ['The gerund breaks the parallel infinitive pattern.', 'This changes from a phrase to an independent clause.', '', 'This passive clause is not parallel with the first two items.'],
    strategy: 'Items in a series should use the same grammatical form.'
  },
  {
    id: 'rwq039', number: 39, domain: 'Standard English Conventions', skill: 'Boundaries', difficulty: 'Hard',
    passage: 'Dr. Amina Patel ______ will lead the new climate laboratory.',
    prompt: 'Which choice completes the text so that it conforms to the conventions of Standard English?',
    choices: [
      'an atmospheric chemist at Western University,',
      ', an atmospheric chemist at Western University,',
      ', an atmospheric chemist at Western University',
      ': an atmospheric chemist at Western University,'
    ],
    answerIndex: 1,
    explanation: 'The appositive is nonessential information and must be enclosed by a comma before and after it.',
    distractors: ['This omits the opening comma.', '', 'This omits the closing comma.', 'A colon cannot be inserted between the subject and this appositive.'],
    strategy: 'If a removable descriptive phrase interrupts a sentence, use matching punctuation on both sides.'
  },
  {
    id: 'rwq040', number: 40, domain: 'Standard English Conventions', skill: 'Form, Structure, and Sense', difficulty: 'Hard',
    passage: 'The survey asked residents not only whether they used the new trail ______',
    prompt: 'Which choice completes the text so that it conforms to the conventions of Standard English?',
    choices: [
      'but also how often they used it.',
      'and also its frequency of use.',
      'but also asking how often it was used.',
      'but how often was the trail used by them.'
    ],
    answerIndex: 0,
    explanation: '“Whether they used” and “how often they used” are parallel indirect-question clauses joined by “not only...but also.”',
    distractors: ['', 'This noun phrase is not parallel with the first clause.', 'The participial phrase is not parallel with “whether they used.”', 'This uses direct-question word order inside an indirect question.'],
    strategy: 'Match the structure after “not only” with the structure after “but also.”'
  }
];
