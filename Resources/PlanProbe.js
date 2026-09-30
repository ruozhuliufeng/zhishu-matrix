(() => {
  let profile = '';
  for (const element of document.querySelectorAll('button,[role=button]')) {
    const rect = element.getBoundingClientRect();
    if (rect.width < 20 || rect.height < 15 || rect.left > 400 || rect.top < innerHeight * 0.55) continue;
    const label = [element.getAttribute('aria-label'), element.innerText].filter(Boolean).join(' ');
    if (/(免费版|团队版|商业版|企业版|教育版|\bFree\b|\bGo\b|\bPlus\b|\bPro\b|\bBusiness\b|\bEnterprise\b|\bEdu\b)/i.test(label) && !/(升级|upgrade)/i.test(label)) {
      profile = label.slice(0, 200);
      break;
    }
  }
  const dialogs = [...document.querySelectorAll('[role=dialog]')].filter(element => element.getClientRects().length);
  const area = dialogs.at(-1) || (/settings|billing|subscription|account/i.test(location.pathname + location.hash) ? document.body : null);
  return { profile, details: area ? area.innerText.slice(0, 40000) : '' };
})()
